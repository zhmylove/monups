#!/usr/bin/perl
# made by: KorG
# vim: ts=4 sw=4 et :

use strict;
use v5.18;
use warnings;
use utf8;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;

# User-defined parameters
my $PROBE_BATTERY = 5;          # Send probes each X seconds when on battery
my $PROBE_NORMAL = 10;          # Send probes each X seconds when on line
my $DELAY_STARTUP = 20;         # Delay X seconds before startup() call
my $UPSD_HOST = "127.0.0.1";    # Host to connect to
my $UPSD_PORT = "3493";         # Port to connect to
my $UPS_NAME = "ippon";         # UPS name to monitor

# Some defines
my $CRLF = "\015\012";
my $connection;
my $current_state = "";
my $end = AnyEvent->condvar;
my $hnd;
my $main_loop;
my @active_timers;

my %states = (
    OL => {
        msg => "On line power now",
        onEnter => sub {
            # Cancel all the timers and startup after threshold time
            @active_timers = AnyEvent->timer(
                after => $DELAY_STARTUP + 0.1,
                cb => sub {
                    # Ensure all is up, revoke actions
                    startup();

                    # Re-create $main_loop with normal timer
                    $main_loop = create_loop($PROBE_NORMAL);
                },
            );
        },
    },
    OB => {
        msg => "On battery now",
        onEnter => sub {
            # Cancel all the timers ASAP
            @active_timers = ();

            # Re-create $main_loop with battery timer to be more reactive
            $main_loop = create_loop($PROBE_BATTERY);

            # We will also monitor the battery charge in order to prepare
            # for an immediate system shutdown on catastrophic discharge
            my $charge_guard;
            $charge_guard = AnyEvent->timer(
                after => 2,
                interval => $PROBE_BATTERY,
                cb => sub {
                    get_var_cb("battery.charge", sub {
                            if ($_[0] =~ m/(\d+)/) {
                                # TODO do something if $1 < threshold
                            } else {
                                notify("Unable to get BAT charge");
                                undef $charge_guard;
                            }
                        });
                }
            );
            push @active_timers, $charge_guard;

            # TODO
            # Create the timers
            # immediately: shutdown VMs and other trash
            # shutdown important services with delay of 1 minute
            # shutdown the system in 5 minutes

        },
    },
);

# Startup all the services
sub startup {
    notify("Running startup routine");
}

# Send a notification in background
sub notify {
    # TODO
    warn "UPS: @_";
}

# Get any $var and call a $cb->($response_line)
sub get_var_cb {
    my ($var, $cb) = @_;
    $hnd->push_write("GET VAR $UPS_NAME $var$CRLF");
    $hnd->push_read(regex => "\015?\012", sub {
            $cb->($_[1]);
        });
}

# Try to make a new connection
sub new_connect {
    $connection = tcp_connect $UPSD_HOST, $UPSD_PORT, sub {
        my ($fh) = @_;
        unless ($fh) {
            notify("Unable to connect: $!");
            return;
        }

        $hnd = AnyEvent::Handle->new(
            fh => $fh,
            on_error => sub {
                notify("ERROR caught in UPSd connection: $_[2]");
                undef $connection;
                $_[0]->destroy;
            },
            on_eof => sub {
                notify("EOF caught in UPSd connection");
                undef $connection;
            },
        );
    };
}

# Every X seconds start the check for UPS status
sub create_loop {
    AnyEvent->timer(
        after => 0,
        interval => $_[0],
        cb => sub {
            return new_connect unless defined $connection;

            get_var_cb("ups.status", sub {
                    # OL is the only proper state, in other cases we suppose
                    # we're at least on a battery and must perform a shutdown
                    my $new_state = "OB";
                    if ($_[0] =~ m/"OL"/) {
                        $new_state = "OL";
                    }

                    # Do something if the new state changed
                    if ($current_state ne $new_state) {
                        # Firstly, send the notification
                        notify($states{$new_state}->{msg});

                        # If $current_state was ever set, call the cb
                        if ($current_state) {
                            # TODO decide if we need any args for this cb
                            $states{$new_state}->{onEnter}->();
                        }

                        # Update the state
                        $current_state = $new_state;
                    }
                });
        });
}

$main_loop = create_loop($PROBE_NORMAL);
$end->recv;
