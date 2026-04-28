##############################################
# $Id: 76_Balboa.pm $
# FHEM Modul fuer Balboa WiFi Whirlpool-Steuerung
# Direktes TCP (Port 4257), Poll-Modus mit Command-Queue
# Protokoll: github.com/ccutrer/balboa_worldwide_app
##############################################

package main;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Time::HiRes qw(gettimeofday);

my $BALBOA_DEFAULT_PORT     = 4257;
my $BALBOA_DEFAULT_INTERVAL = 180;

my %BALBOA_TOGGLE = (
    pump1    => 0x04,
    pump2    => 0x05,
    pump3    => 0x06,
    light    => 0x11,
    blower   => 0x0C,
    heatMode => 0x51,
    tempRange => 0x50,
);

my @BALBOA_PUMP_STATES = (0, 1, 2, "unknown");
my @BALBOA_HEAT_MODES  = qw(ready rest unknown ready_in_rest);

sub Balboa_Initialize($) {
    my ($hash) = @_;
    $hash->{DefFn}    = "Balboa_Define";
    $hash->{UndefFn}  = "Balboa_Undef";
    $hash->{SetFn}    = "Balboa_Set";
    $hash->{GetFn}    = "Balboa_Get";
    $hash->{AttrFn}   = "Balboa_Attr";
    $hash->{AttrList} = "interval:60,120,180,300,600 "
                      . "tempOffset:slider,-5,0.5,5 "
                      . "disable:0,1 "
                      . $readingFnAttributes;
}

sub Balboa_Define($$) {
    my ($hash, $def) = @_;
    my @a = split(/\s+/, $def);
    return "Usage: define <name> Balboa <ip> [<port>]" if @a < 3;

    $hash->{IP}   = $a[2];
    $hash->{PORT} = defined($a[3]) ? $a[3] : $BALBOA_DEFAULT_PORT;
    $hash->{helper}{CMD_QUEUE}   = [];
    $hash->{helper}{RUNNING_PID} = undef;

    readingsSingleUpdate($hash, "state", "defined", 1);
    InternalTimer(gettimeofday() + 5, "Balboa_Poll", $hash, 0);
    return undef;
}

sub Balboa_Undef($$) {
    my ($hash, $name) = @_;
    RemoveInternalTimer($hash);
    BlockingKill($hash->{helper}{RUNNING_PID}) if $hash->{helper}{RUNNING_PID};
    return undef;
}

sub Balboa_Attr($$$$) {
    my ($cmd, $name, $attr, $val) = @_;
    my $hash = $defs{$name};
    if ($attr eq "disable") {
        if ($cmd eq "set" && $val == 1) {
            RemoveInternalTimer($hash);
            BlockingKill($hash->{helper}{RUNNING_PID}) if $hash->{helper}{RUNNING_PID};
            readingsSingleUpdate($hash, "state", "disabled", 1);
        } else {
            InternalTimer(gettimeofday() + 2, "Balboa_Poll", $hash, 0);
        }
    }
    return undef;
}

##############################################
# CRC-8: poly=0x07, init=0x02, xorout=0x02
# Eingabe: LEN-Byte + Type-Bytes + Payload
##############################################
sub Balboa_CRC8($) {
    my ($data) = @_;
    my $crc = 0x02;
    for my $byte (unpack('C*', $data)) {
        $crc ^= $byte;
        for (1..8) {
            $crc = ($crc & 0x80)
                ? ((($crc << 1) ^ 0x07) & 0xFF)
                : (($crc << 1) & 0xFF);
        }
    }
    return $crc ^ 0x02;
}

##############################################
# Frame bauen: 7E [LEN] [TYPE] [PAYLOAD] [CRC] 7E
# LEN = length(type) + length(payload) + 2 (CRC-Byte + End-7E)
# Bestaetigt durch ccutrer/pybalboa: len = type + data + 2
##############################################
sub Balboa_BuildMsg($$) {
    my ($type, $payload) = @_;
    my $len  = length($type) + length($payload) + 2;
    my $body = pack('C', $len) . $type . $payload;
    return "\x7E" . $body . pack('C', Balboa_CRC8($body)) . "\x7E";
}

##############################################
# Einen vollstaendigen Frame aus Socket lesen (mit Timeout)
# Frame-Format: 7E(1) + LEN_byte(1) + LEN_bytes + 7E(1)
# Gesamt = LEN + 3 Bytes
##############################################
sub Balboa_ReadFrame($$) {
    my ($sock, $timeout_sec) = @_;
    my $sel = IO::Select->new($sock);
    my ($buf, $frame_len) = ("", 0);
    my $deadline = time() + $timeout_sec;

    while (time() < $deadline) {
        my $remaining = $deadline - time();
        last if $remaining <= 0;
        next unless $sel->can_read($remaining);  # warten bis Daten da

        my $byte = "";
        my $n = sysread($sock, $byte, 1);
        last unless defined($n) && $n == 1;

        # Auf Start-Byte 0x7E warten
        if (!length($buf)) {
            next unless ord($byte) == 0x7E;
        }
        $buf .= $byte;

        # LEN-Byte ist Byte Nr. 2
        if (length($buf) == 2) {
            $frame_len = ord($byte);
        }

        # Vollstaendiger Frame: start_7E(1) + LEN_byte(1) + frame_len + end_7E(1)
        if ($frame_len > 0 && length($buf) >= $frame_len + 3) {
            if (ord(substr($buf, -1)) == 0x7E) {
                return $buf;
            }
            # Kaputtes Frame – Buffer zuruecksetzen
            Log3(undef, 5, "Balboa: corrupt frame " . unpack('H*', $buf));
            ($buf, $frame_len) = ("", 0);
        }
    }
    return undef;
}

##############################################
# Status-Frame parsen -> Hash-Ref oder undef
##############################################
sub Balboa_ParseStatusFrame($) {
    my ($frame) = @_;
    return undef if length($frame) < 9;

    my $type    = substr($frame, 2, 3);
    my $payload = substr($frame, 5, length($frame) - 7);

    # Nur Status-Updates (FF AF 13 oder FF AF 16) akzeptieren
    unless ($type eq "\xFF\xAF\x13" || $type eq "\xFF\xAF\x16") {
        return undef;
    }
    return undef if length($payload) < 21;

    my @b = unpack('C*', $payload);

    my $isCelsius = ($b[9] & 0x01) ? 1 : 0;

    my ($temp, $setTemp) = ("unknown", "unknown");
    if ($b[2] != 0xFF) {
        $temp = $isCelsius ? $b[2] / 2.0 : ($b[2] - 32) * 5.0 / 9.0;
        $temp = sprintf("%.1f", $temp);
    }
    if ($b[20] != 0xFF) {
        $setTemp = $isCelsius ? $b[20] / 2.0 : ($b[20] - 32) * 5.0 / 9.0;
        $setTemp = sprintf("%.1f", $setTemp);
    }

    return {
        isCelsius   => $isCelsius,
        temp        => $temp,
        setTemp     => $setTemp,
        pump1       => $BALBOA_PUMP_STATES[$b[11] & 0x03]        // "unknown",
        pump2       => $BALBOA_PUMP_STATES[($b[11] >> 2) & 0x03] // "unknown",
        light       => ($b[14] & 0x03) ? 1 : 0,
        heating     => ($b[10] & 0x30) ? 1 : 0,
        heatingMode => $BALBOA_HEAT_MODES[$b[5] & 0x03] // "unknown",
        timeHour    => $b[3],
        timeMin     => $b[4],
        tempRange   => ($b[10] >> 2) & 0x01,
        filter1Run  => ($b[9]  >> 2) & 0x01,
        filter2Run  => ($b[9]  >> 3) & 0x01,
        rawHex      => join(' ', map { sprintf('%02X', $_) } @b),
    };
}

##############################################
# BlockingCall-Hintergrundprozess
# Liest Status, sendet ggf. gequeuete Befehle,
# liest dann erneut Status zur Bestaetigung.
#
# Args: "name|ip|port|isCelsius|CMD1|CMD2|..."
# CMD-Format: "setTemp:RAW" | "toggle:item:count"
##############################################
sub Balboa_Poll_BG($) {
    my ($args) = @_;
    my ($name, $ip, $port, $isCelsius_hint, @cmds) = split(/\|/, $args);

    my $sock = IO::Socket::INET->new(
        PeerAddr => $ip,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    );
    return "$name|ERR|connect failed: $!" unless $sock;

    # Status lesen (Spa sendet automatisch alle ~1s)
    my $status;
    for (1..8) {
        my $frame = Balboa_ReadFrame($sock, 2);
        next unless $frame;  # Timeout oder falsches Frame -> weiter versuchen
        $status = Balboa_ParseStatusFrame($frame);
        last if $status;
    }

    unless ($status) {
        $sock->close();
        return "$name|ERR|no status frame received";
    }

    # Gequeuete Befehle senden
    my @valid_cmds = grep { /^(setTemp|toggle|setScale|setTime|setFilter):/ } @cmds;
    my @sent_log   = ();
    if (@valid_cmds) {
        my $isCelsius = $status->{isCelsius};
        my $executed  = 0;

        for my $cmd (@valid_cmds) {
            if ($cmd =~ /^setTemp:(\d+)/) {
                my $raw = int($1);
                # raw = temp_C * 2; bei Fahrenheit-Spa umrechnen
                my $send_raw = $isCelsius ? $raw : int($raw * 9.0 / 10 + 32);
                $send_raw = 255 if $send_raw > 255;
                my $msg = Balboa_BuildMsg(pack('CCC', 0x0A, 0xBF, 0x20), pack('C', $send_raw));
                syswrite($sock, $msg);
                push @sent_log, "setTemp raw=$send_raw hex=" . unpack('H*', $msg);
                $executed++;
            }
            elsif ($cmd =~ /^toggle:(\w+):(\d+)/) {
                my ($item, $count) = ($1, $2);
                my $code = $BALBOA_TOGGLE{$item};
                next unless defined($code);
                my $msg = Balboa_BuildMsg(pack('CCC', 0x0A, 0xBF, 0x11), pack('CC', $code, 0x00));
                for (1..$count) {
                    syswrite($sock, $msg);
                    select(undef, undef, undef, 0.15) if $_ < $count;
                }
                push @sent_log, "toggle $item x$count code=" . sprintf('0x%02X', $code) . " hex=" . unpack('H*', $msg);
                $executed++;
            }
            elsif ($cmd =~ /^setScale:([01])(?::\d+)?$/) {
                my $unit = int($1);  # 0=F, 1=C
                my $msg = Balboa_BuildMsg(pack('CCC', 0x0A, 0xBF, 0x27), pack('CC', 0x01, $unit));
                syswrite($sock, $msg);
                push @sent_log, "setScale unit=$unit hex=" . unpack('H*', $msg);
                $executed++;
            }
            elsif ($cmd =~ /^setTime:(\d{2}):(\d{2})(?::\d+)?$/) {
                my ($h, $m) = (int($1), int($2));
                my $msg = Balboa_BuildMsg(pack('CCC', 0x0A, 0xBF, 0x21), pack('CC', 0x80 | $h, $m));
                syswrite($sock, $msg);
                push @sent_log, "setTime ${h}:${m} hex=" . unpack('H*', $msg);
                $executed++;
            }
            elsif ($cmd =~ /^setFilter:(\d+):(\d+):(\d+):(\d+):(\d+):(\d+):(\d+):(\d+)(?::\d+)?$/) {
                my @bytes = map { int($_) } ($1,$2,$3,$4,$5,$6,$7,$8);
                my $msg = Balboa_BuildMsg(pack('CCC', 0x0A, 0xBF, 0x23), pack('C8', @bytes));
                syswrite($sock, $msg);
                push @sent_log, "setFilter " . join(',', @bytes) . " hex=" . unpack('H*', $msg);
                $executed++;
            }
        }

        # Nach Befehlen kurz warten und aktualisierten Status lesen
        select(undef, undef, undef, 0.8);
        for (1..5) {
            my $frame = Balboa_ReadFrame($sock, 2);
            next unless $frame;
            my $new = Balboa_ParseStatusFrame($frame);
            if ($new) { $status = $new; last; }
        }
    }

    # Filter-Cycle-Daten anfordern (0A BF 22, SettingsCode=0x01)
    my ($f1_start, $f1_dur, $f2_en, $f2_start, $f2_dur) = ("unknown","unknown",0,"unknown","unknown");
    my $freq = Balboa_BuildMsg(pack('CCC', 0x0A, 0xBF, 0x22), pack('CCC', 0x01, 0x00, 0x00));
    syswrite($sock, $freq);
    for (1..8) {
        my $frame = Balboa_ReadFrame($sock, 2);
        next unless $frame;
        next if length($frame) < 9;
        my $ftype = substr($frame, 2, 3);
        if ($ftype eq "\xFF\xAF\x23") {
            my $pl = substr($frame, 5, length($frame) - 7);
            if (length($pl) >= 8) {
                my @b = unpack('C*', $pl);
                $f1_start = sprintf("%02d:%02d", $b[0], $b[1]);
                $f1_dur   = sprintf("%02d:%02d", $b[2], $b[3]);
                $f2_en    = ($b[4] & 0x80) ? 1 : 0;
                $f2_start = sprintf("%02d:%02d", ($b[4] & 0x7F), $b[5]);
                $f2_dur   = sprintf("%02d:%02d", $b[6], $b[7]);
                last;
            }
        }
    }

    $sock->close();

    my $sent_info = @sent_log ? join('; ', @sent_log) : "";

    return join('|',
        $name,
        "OK",
        scalar(@valid_cmds),  # Anzahl ausgefuehrter Befehle
        $sent_info,
        $status->{isCelsius},
        $status->{temp},
        $status->{setTemp},
        $status->{pump1},
        $status->{pump2},
        $status->{light},
        $status->{heating},
        $status->{heatingMode},
        sprintf("%02d:%02d", $status->{timeHour}, $status->{timeMin}),
        $status->{tempRange} ? "high" : "low",
        $status->{filter1Run},
        $status->{filter2Run},
        $f1_start,
        $f1_dur,
        $f2_en,
        $f2_start,
        $f2_dur,
        $status->{rawHex},
    );
}

sub Balboa_Poll_Done($) {
    my ($result) = @_;
    my ($name, $status, @data) = split(/\|/, $result);
    my $hash = $defs{$name};
    return unless $hash;
    delete $hash->{helper}{RUNNING_PID};

    if ($status eq "ERR") {
        Log3($name, 3, "Balboa $name: poll error: $data[0]");
        readingsSingleUpdate($hash, "state", "disconnected", 1);
        return;
    }

    my ($cmd_count, $sent_info, $isCelsius, $temp, $setTemp, $pump1, $pump2, $light, $heating, $heatingMode,
        $timeOfDay, $tempRange, $filter1Running, $filter2Running,
        $filter1Start, $filter1Duration, $filter2Enabled, $filter2Start, $filter2Duration,
        @rawParts) = @data;

    # Ausfuehrung der gequeueten Befehle bestaetigt -> Queue leeren + verifizieren
    if ($cmd_count > 0) {
        Log3($name, 3, "Balboa $name: $cmd_count Befehl(e) gesendet: $sent_info");
        splice(@{$hash->{helper}{CMD_QUEUE}}, 0, $cmd_count);

        # Pruefen ob Befehle Wirkung gezeigt haben; ggf. Retry in Queue
        my @sent     = @{$hash->{helper}{LAST_SENT_CMDS} // []};
        my $offset   = AttrVal($name, "tempOffset", 0);
        my %actuals  = (
            pump1     => $pump1,
            pump2     => $pump2,
            light     => $light,
            heatMode  => $heatingMode,
            tempRange => $tempRange,
            tempScale => ($isCelsius ? "C" : "F"),
            timeOfDay => $timeOfDay,
        );
        my @retries;

        my $now = time();
        for my $c (grep { /^(setTemp|toggle|setScale|setTime):/ } @sent) {
            if ($c =~ /^setTemp:(\d+):(\d+)$/) {
                my ($raw, $deadline) = ($1, $2);
                my $expected = sprintf("%.1f", $raw / 2.0 + $offset);
                if ($setTemp eq "unknown" || abs($setTemp - $expected) > 0.6) {
                    if ($now < $deadline) {
                        push @retries, "setTemp:$raw:$deadline";
                        my $min_left = int(($deadline - $now) / 60);
                        Log3($name, 2, "Balboa $name: setTemp erwartet=$expected gelesen=$setTemp -> Retry (noch ${min_left} Min)");
                    } else {
                        Log3($name, 2, "Balboa $name: setTemp $expected nach 15 Min Timeout aufgegeben");
                    }
                } else {
                    Log3($name, 3, "Balboa $name: setTemp $expected bestaetigt");
                }
            }
            elsif ($c =~ /^toggle:(\w+):(\d+):(\d+):(\w+)$/) {
                my ($item, $count, $deadline, $expected) = ($1, $2, $3, $4);
                my $actual = $actuals{$item} // "unknown";
                if ($actual ne $expected) {
                    if ($now < $deadline) {
                        push @retries, "toggle:$item:$count:$deadline:$expected";
                        my $min_left = int(($deadline - $now) / 60);
                        Log3($name, 2, "Balboa $name: $item erwartet=$expected gelesen=$actual -> Retry (noch ${min_left} Min)");
                    } else {
                        Log3($name, 2, "Balboa $name: $item $expected nach 15 Min Timeout aufgegeben");
                    }
                } else {
                    Log3($name, 3, "Balboa $name: $item $expected bestaetigt");
                }
            }
            elsif ($c =~ /^setScale:([01]):(\d+)$/) {
                my ($unit, $deadline) = ($1, $2);
                my $expected = $unit ? "C" : "F";
                my $actual   = $actuals{tempScale};
                if ($actual ne $expected) {
                    if ($now < $deadline) {
                        push @retries, "setScale:$unit:$deadline";
                        Log3($name, 2, "Balboa $name: tempScale erwartet=$expected gelesen=$actual -> Retry");
                    } else {
                        Log3($name, 2, "Balboa $name: tempScale $expected nach Timeout aufgegeben");
                    }
                } else {
                    Log3($name, 3, "Balboa $name: tempScale $expected bestaetigt");
                }
            }
            elsif ($c =~ /^setTime:(\d{2}:\d{2}):(\d+)$/) {
                my ($expected, $deadline) = ($1, $2);
                my $actual = $actuals{timeOfDay};
                if ($actual ne $expected) {
                    if ($now < $deadline) {
                        push @retries, "setTime:$expected:$deadline";
                        Log3($name, 2, "Balboa $name: timeOfDay erwartet=$expected gelesen=$actual -> Retry");
                    } else {
                        Log3($name, 2, "Balboa $name: timeOfDay $expected nach Timeout aufgegeben");
                    }
                } else {
                    Log3($name, 3, "Balboa $name: timeOfDay $expected bestaetigt");
                }
            }
        }
        # Fehlgeschlagene Befehle vorne in Queue einfuegen
        unshift @{$hash->{helper}{CMD_QUEUE}}, @retries if @retries;
    }

    my $offset = AttrVal($name, "tempOffset", 0);
    $temp    = sprintf("%.1f", $temp + $offset)    if $temp    ne "unknown";
    $setTemp = sprintf("%.1f", $setTemp + $offset) if $setTemp ne "unknown";

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "state",       "connected");
    readingsBulkUpdate($hash, "temp",        $temp);
    readingsBulkUpdate($hash, "setTemp",     $setTemp);
    readingsBulkUpdate($hash, "pump1",       $pump1);
    readingsBulkUpdate($hash, "pump2",       $pump2);
    readingsBulkUpdate($hash, "light",       $light);
    readingsBulkUpdate($hash, "heating",     $heating);
    readingsBulkUpdate($hash, "heatingMode",    $heatingMode);
    readingsBulkUpdate($hash, "tempScale",      $isCelsius ? "C" : "F");
    readingsBulkUpdate($hash, "timeOfDay",      $timeOfDay);
    readingsBulkUpdate($hash, "tempRange",      $tempRange);
    readingsBulkUpdate($hash, "filter1Running",  $filter1Running);
    readingsBulkUpdate($hash, "filter2Running",  $filter2Running);
    readingsBulkUpdate($hash, "filter1Start",    $filter1Start)    if $filter1Start    ne "unknown";
    readingsBulkUpdate($hash, "filter1Duration", $filter1Duration) if $filter1Duration ne "unknown";
    readingsBulkUpdate($hash, "filter2Enabled",  $filter2Enabled);
    readingsBulkUpdate($hash, "filter2Start",    $filter2Start)    if $filter2Start    ne "unknown";
    readingsBulkUpdate($hash, "filter2Duration", $filter2Duration) if $filter2Duration ne "unknown";
    readingsBulkUpdate($hash, "faultCode",       "255");
    readingsBulkUpdate($hash, "faultMessage",   "Spa OK");
    readingsBulkUpdate($hash, "rawStatus",      join(' ', @rawParts));
    readingsEndUpdate($hash, 1);

    Log3($name, 4, "Balboa $name: temp=$temp setTemp=$setTemp pump1=$pump1 pump2=$pump2 light=$light heating=$heating scale=" . ($isCelsius ? "C" : "F"));

    # Noch Befehle in Queue? -> sofort naechsten Poll ausloesen
    if (@{$hash->{helper}{CMD_QUEUE} // []}) {
        Log3($name, 3, "Balboa $name: " . scalar(@{$hash->{helper}{CMD_QUEUE}}) . " Befehl(e) noch in Queue, starte Poll in 1s");
        RemoveInternalTimer($hash, "Balboa_Poll");
        InternalTimer(gettimeofday() + 1, "Balboa_Poll", $hash, 0);
    }
}

sub Balboa_Poll_Aborted($) {
    my ($hash) = @_;
    delete $hash->{helper}{RUNNING_PID};
    Log3($hash->{NAME}, 2, "Balboa $hash->{NAME}: poll timed out");
    readingsSingleUpdate($hash, "state", "timeout", 1);
}

##############################################
# Periodischer Poll: serialisiert CMD_QUEUE und
# startet BlockingCall
##############################################
sub Balboa_Poll($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash, "Balboa_Poll");
    return if AttrVal($name, "disable", 0);

    if ($hash->{helper}{RUNNING_PID}) {
        Log3($name, 4, "Balboa $name: poll laeuft noch, ueberspringe");
    } else {
        my $isCelsius = (ReadingsVal($name, "tempScale", "C") eq "C") ? 1 : 0;

        # CMD_QUEUE in Pipe-getrennten String serialisieren
        my @cmds = @{$hash->{helper}{CMD_QUEUE} // []};
        $hash->{helper}{LAST_SENT_CMDS} = [@cmds];  # Snapshot fuer Verifikation in Poll_Done
        my $args = join('|', $name, $hash->{IP}, $hash->{PORT}, $isCelsius, @cmds);

        Log3($name, 4, "Balboa $name: starte Poll" . (@cmds ? " mit " . scalar(@cmds) . " Befehl(en)" : ""));

        $hash->{helper}{RUNNING_PID} = BlockingCall(
            "Balboa_Poll_BG",
            $args,
            "Balboa_Poll_Done",
            25,
            "Balboa_Poll_Aborted",
            $hash,
        );
    }

    my $interval = AttrVal($name, "interval", $BALBOA_DEFAULT_INTERVAL);
    InternalTimer(gettimeofday() + $interval, "Balboa_Poll", $hash, 0);
}

##############################################
# Hilfsfunktion: Toggle-Anzahl berechnen
# Pumpenzyklus: off(0) -> low(1) -> high(2) -> off(0)
##############################################
sub Balboa_ToggleCount($$$) {
    my ($item, $current, $desired) = @_;
    return 0 if $current == $desired;
    return 1 if $item eq "light";

    my $c = int($current // 0);
    my $d = int($desired  // 0);
    return ($d - $c + 3) % 3;
}

##############################################
# Set-Befehle: Befehl in Queue stellen und
# sofortigen Poll ausloesen
##############################################
sub Balboa_Set($$$@) {
    my ($hash, $name, $cmd, @args) = @_;

    my $list = "setTemp:slider,10,0.5,37 "
             . "pump1:0,1,2 pump2:0,1,2 "
             . "light:0,1 "
             . "heatMode:ready,rest "
             . "tempRange:low,high "
             . "tempScale:C,F "
             . "setTime "
             . "filterCycle1 "
             . "filterCycle2 "
             . "statusRequest:noArg";

    return $list if $cmd eq "?";
    return "Modul ist deaktiviert" if AttrVal($name, "disable", 0);

    # --- statusRequest ---
    if ($cmd eq "statusRequest") {
        RemoveInternalTimer($hash, "Balboa_Poll");
        InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        return undef;
    }

    # --- setTemp ---
    if ($cmd eq "setTemp") {
        my $temp = $args[0];
        return "Bitte Temperatur angeben (10-37 Grad)"
            unless defined($temp) && $temp =~ /^\d+(\.\d+)?$/ && $temp >= 10 && $temp <= 37;

        # Rohwert immer in Celsius*2 speichern; BG-Prozess konvertiert bei Bedarf
        my $raw      = int($temp * 2);
        my $deadline = time() + 15 * 60;  # 15 Minuten Timeout
        push @{$hash->{helper}{CMD_QUEUE}}, "setTemp:$raw:$deadline";

        Log3($name, 3, "Balboa $name: setTemp $temp°C in Queue (raw=$raw)");

        # Sofortigen Poll ausloesen (falls keiner laeuft)
        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    # --- pump1 / pump2 ---
    if ($cmd eq "pump1" || $cmd eq "pump2") {
        my $desired = $args[0] // "";
        return "Bitte 0, 1 oder 2 angeben" unless $desired =~ /^(0|1|2)$/;
        $desired = int($desired);

        my $current = int(ReadingsVal($name, $cmd, 0));
        my $toggles = Balboa_ToggleCount($cmd, $current, $desired);

        my $newState = $desired;
        my $deadline = time() + 15 * 60;
        if ($toggles > 0) {
            push @{$hash->{helper}{CMD_QUEUE}}, "toggle:$cmd:$toggles:$deadline:$newState";
            Log3($name, 3, "Balboa $name: $cmd $current -> $newState ($toggles Toggles) in Queue");
        }
        readingsSingleUpdate($hash, $cmd, $newState, 1);  # optimistisch

        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    # --- light ---
    if ($cmd eq "light") {
        my $desired = $args[0] // "";
        return "Bitte 0 oder 1 angeben" unless $desired =~ /^(0|1)$/;
        $desired = int($desired);

        my $current = int(ReadingsVal($name, "light", 0));
        if ($current ne $desired) {
            my $deadline = time() + 15 * 60;
            push @{$hash->{helper}{CMD_QUEUE}}, "toggle:light:1:$deadline:$desired";
            Log3($name, 3, "Balboa $name: light $current -> $desired in Queue");
        }

        readingsSingleUpdate($hash, "light", $desired, 1);  # optimistisch

        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    # --- heatMode ---
    if ($cmd eq "heatMode") {
        my $desired = $args[0] // "";
        return "Bitte ready oder rest angeben" unless $desired =~ /^(ready|rest)$/;

        my %mode_num = (ready => 0, rest => 1, ready_in_rest => 3);
        my $current_str = ReadingsVal($name, "heatingMode", "ready");
        my $current = $mode_num{$current_str} // 0;
        my $desired_num = $mode_num{$desired};
        # Zyklus: 0(ready)->1(rest)->3(ready_in_rest)->0; wir togglen nur zu ready/rest
        # Anzahl Toggles mod 3 vom current zum desired
        my $toggles = ($desired_num - $current + 3) % 3;

        if ($toggles > 0) {
            my $deadline = time() + 15 * 60;
            push @{$hash->{helper}{CMD_QUEUE}}, "toggle:heatMode:$toggles:$deadline:$desired";
            Log3($name, 3, "Balboa $name: heatMode $current_str -> $desired ($toggles Toggles) in Queue");
        }

        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    # --- tempRange ---
    if ($cmd eq "tempRange") {
        my $desired = $args[0] // "";
        return "Bitte low oder high angeben" unless $desired =~ /^(low|high)$/;

        my $current = ReadingsVal($name, "tempRange", "low");
        if ($current ne $desired) {
            my $deadline = time() + 15 * 60;
            push @{$hash->{helper}{CMD_QUEUE}}, "toggle:tempRange:1:$deadline:$desired";
            Log3($name, 3, "Balboa $name: tempRange $current -> $desired in Queue");
        }

        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    # --- tempScale ---
    if ($cmd eq "tempScale") {
        my $desired = $args[0] // "";
        return "Bitte C oder F angeben" unless $desired =~ /^(C|F)$/;

        my $unit     = ($desired eq "C") ? 1 : 0;
        my $current  = ReadingsVal($name, "tempScale", "C");
        if ($current ne $desired) {
            my $deadline = time() + 15 * 60;
            push @{$hash->{helper}{CMD_QUEUE}}, "setScale:$unit:$deadline";
            Log3($name, 3, "Balboa $name: tempScale $current -> $desired in Queue");
        }

        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    # --- setTime ---
    if ($cmd eq "setTime") {
        my $time_str = $args[0] // "";
        return "Bitte Zeit im Format HH:MM angeben"
            unless $time_str =~ /^(\d{1,2}):(\d{2})$/ && $1 <= 23 && $2 <= 59;

        my $normalized = sprintf("%02d:%02d", $1, $2);
        my $deadline   = time() + 5 * 60;
        push @{$hash->{helper}{CMD_QUEUE}}, "setTime:$normalized:$deadline";
        Log3($name, 3, "Balboa $name: setTime $normalized in Queue");

        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    # --- filterCycle1 HH:MM HH:MM (start duration) ---
    if ($cmd eq "filterCycle1") {
        my ($start, $dur) = @args;
        return "Syntax: filterCycle1 HH:MM HH:MM (Start Dauer)"
            unless defined($dur)
            && $start =~ /^(\d{1,2}):(\d{2})$/ && $1 <= 23 && $2 <= 59
            && $dur   =~ /^(\d{1,2}):(\d{2})$/;

        my ($s_h, $s_m) = $start =~ /^(\d+):(\d+)$/;
        my ($d_h, $d_m) = $dur   =~ /^(\d+):(\d+)$/;

        # Zyklus-2-Werte aus aktuellen Readings lesen
        my $f2_en  = int(ReadingsVal($name, "filter2Enabled", 0));
        my ($f2_sh, $f2_sm) = split(/:/, ReadingsVal($name, "filter2Start",    "00:00"));
        my ($f2_dh, $f2_dm) = split(/:/, ReadingsVal($name, "filter2Duration", "00:00"));
        $f2_sh //= 0; $f2_sm //= 0; $f2_dh //= 0; $f2_dm //= 0;

        my $b4 = ($f2_en << 7) | (int($f2_sh) & 0x7F);
        my $deadline = time() + 15 * 60;
        push @{$hash->{helper}{CMD_QUEUE}},
            "setFilter:$s_h:$s_m:$d_h:$d_m:$b4:$f2_sm:$f2_dh:$f2_dm:$deadline";
        Log3($name, 3, "Balboa $name: filterCycle1 start=$start dur=$dur in Queue");

        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    # --- filterCycle2 0|1 HH:MM HH:MM (enabled start duration) ---
    if ($cmd eq "filterCycle2") {
        my ($en_str, $start, $dur) = @args;
        return "Syntax: filterCycle2 0|1 HH:MM HH:MM (Aktiv Start Dauer)"
            unless defined($dur) && $en_str =~ /^[01]$/
            && $start =~ /^(\d{1,2}):(\d{2})$/ && $1 <= 23 && $2 <= 59
            && $dur   =~ /^(\d{1,2}):(\d{2})$/;

        my $f2_en  = int($en_str);
        my ($s_h, $s_m) = $start =~ /^(\d+):(\d+)$/;
        my ($d_h, $d_m) = $dur   =~ /^(\d+):(\d+)$/;

        # Zyklus-1-Werte aus aktuellen Readings lesen
        my ($f1_sh, $f1_sm) = split(/:/, ReadingsVal($name, "filter1Start",    "00:00"));
        my ($f1_dh, $f1_dm) = split(/:/, ReadingsVal($name, "filter1Duration", "00:00"));
        $f1_sh //= 0; $f1_sm //= 0; $f1_dh //= 0; $f1_dm //= 0;

        my $b4 = ($f2_en << 7) | (int($s_h) & 0x7F);
        my $deadline = time() + 15 * 60;
        push @{$hash->{helper}{CMD_QUEUE}},
            "setFilter:$f1_sh:$f1_sm:$f1_dh:$f1_dm:$b4:$s_m:$d_h:$d_m:$deadline";
        Log3($name, 3, "Balboa $name: filterCycle2 en=$f2_en start=$start dur=$dur in Queue");

        unless ($hash->{helper}{RUNNING_PID}) {
            RemoveInternalTimer($hash, "Balboa_Poll");
            InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        }
        return undef;
    }

    return "Unbekannter Befehl '$cmd', verfuegbar: $list";
}

##############################################
# Get-Befehle
##############################################
sub Balboa_Get($$$@) {
    my ($hash, $name, $cmd, @args) = @_;
    return "Verfuegbar: status" if $cmd eq "?";

    if ($cmd eq "status") {
        RemoveInternalTimer($hash, "Balboa_Poll");
        InternalTimer(gettimeofday() + 0.5, "Balboa_Poll", $hash, 0);
        return undef;
    }
    return "Unbekannte Abfrage: $cmd";
}

1;

=pod
=item device
=item summary Balboa WiFi Whirlpool-Steuerung (direktes TCP, Poll-Modus)
=item summary_DE Balboa WLAN Whirlpool via TCP Port 4257

=begin html
<a name="Balboa"></a>
<h3>Balboa</h3>
<ul>
  FHEM-Modul zur direkten TCP-Steuerung von Balboa WiFi Whirlpool-Controllern.<br>
  Verbindet sich alle N Sekunden kurz (Poll-Modus), damit die offizielle Balboa-App
  parallel genutzt werden kann. Set-Befehle werden in einer Queue gesammelt und beim
  naechsten Poll-Zyklus in derselben TCP-Verbindung ausgefuehrt.<br><br>

  <b>Define</b><br>
  <ul>
    <code>define &lt;name&gt; Balboa &lt;ip&gt; [&lt;port&gt;]</code><br>
    Standard-Port: 4257<br>
    Beispiel: <code>define Whirlpool Balboa 192.168.178.127</code>
  </ul><br>

  <b>Set-Befehle</b><br>
  <ul>
    <li><code>setTemp &lt;10-37&gt;</code> &ndash; Soll-Temperatur in &deg;C</li>
    <li><code>pump1 0|1|2</code> &ndash; Pumpe 1 (0=aus, 1=an, 2=hoch)</li>
    <li><code>pump2 0|1|2</code> &ndash; Pumpe 2 (0=aus, 1=an, 2=hoch)</li>
    <li><code>light 0|1</code> &ndash; Licht (0=aus, 1=an)</li>
    <li><code>heatMode ready|rest</code> &ndash; Heizmodus umschalten</li>
    <li><code>tempRange low|high</code> &ndash; Temperatur-Bereich umschalten</li>
    <li><code>tempScale C|F</code> &ndash; Temperatur-Einheit setzen</li>
    <li><code>setTime HH:MM</code> &ndash; Spa-Uhrzeit setzen</li>
    <li><code>filterCycle1 HH:MM HH:MM</code> &ndash; Filterzyklus 1: Startzeit und Dauer</li>
    <li><code>filterCycle2 0|1 HH:MM HH:MM</code> &ndash; Filterzyklus 2: Aktiv, Startzeit, Dauer</li>
    <li><code>statusRequest</code> &ndash; Sofortiger Poll</li>
  </ul><br>

  <b>Readings</b><br>
  <ul>
    <li><code>temp</code> &ndash; Ist-Temperatur (&deg;C)</li>
    <li><code>setTemp</code> &ndash; Soll-Temperatur (&deg;C)</li>
    <li><code>pump1, pump2</code> &ndash; 0 (aus) / 1 (an) / 2 (hoch)</li>
    <li><code>light</code> &ndash; 0 (aus) / 1 (an)</li>
    <li><code>heating</code> &ndash; 0 (aus) / 1 (an)</li>
    <li><code>heatingMode</code> &ndash; ready / rest / ready_in_rest</li>
    <li><code>tempScale</code> &ndash; C / F (vom Spa gemeldete Einheit)</li>
    <li><code>timeOfDay</code> &ndash; Spa-interne Uhrzeit (HH:MM)</li>
    <li><code>tempRange</code> &ndash; low / high (Temperatur-Bereich)</li>
    <li><code>filter1Running</code> &ndash; 0 / 1 (Filterzyklus 1 l&auml;uft gerade)</li>
    <li><code>filter2Running</code> &ndash; 0 / 1 (Filterzyklus 2 l&auml;uft gerade)</li>
    <li><code>filter1Start</code> &ndash; Startzeit Zyklus 1 (HH:MM)</li>
    <li><code>filter1Duration</code> &ndash; Dauer Zyklus 1 (HH:MM)</li>
    <li><code>filter2Enabled</code> &ndash; 0 / 1 (Zyklus 2 aktiviert)</li>
    <li><code>filter2Start</code> &ndash; Startzeit Zyklus 2 (HH:MM)</li>
    <li><code>filter2Duration</code> &ndash; Dauer Zyklus 2 (HH:MM)</li>
    <li><code>faultCode</code> &ndash; 255 = kein Fehler</li>
    <li><code>rawStatus</code> &ndash; Rohbytes fuer Diagnose (verbose 4)</li>
    <li><code>state</code> &ndash; connected / disconnected / timeout / disabled</li>
  </ul><br>

  <b>Attribute</b><br>
  <ul>
    <li><code>interval</code> &ndash; Poll-Intervall in Sekunden (Standard: 180)</li>
    <li><code>tempOffset</code> &ndash; Temperatur-Kalibrierungsoffset</li>
    <li><code>disable 0|1</code> &ndash; Polling deaktivieren</li>
  </ul>
</ul>
=end html
=cut
