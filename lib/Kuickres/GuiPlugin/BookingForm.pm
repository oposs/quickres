package Kuickres::GuiPlugin::BookingForm;
use Mojo::Base 'CallBackery::GuiPlugin::AbstractForm', -signatures;
use CallBackery::Translate qw(trm);
use CallBackery::Exception qw(mkerror);
use Mojo::JSON qw(true false);
use Mojo::Util qw(dumper);
use Time::Piece qw(localtime);
use POSIX qw(strftime);
use Kuickres::Email;

=head1 NAME

Kuickres::GuiPlugin::BookingForm - Song Edit Form

=head1 SYNOPSIS

 use Kuickres::GuiPlugin::BookingForm;

=head1 DESCRIPTION

The Booking Edit Form

=cut

has checkAccess => sub {
    my $self = shift;
    return 0 if $self->user->userId eq '__ROOT';
    return $self->user->may('booker') || $self->user->may('admin');
};

=head1 METHODS

All the methods of L<CallBackery::GuiPlugin::AbstractForm> plus:

=cut

sub db {
    shift->user->mojoSqlDb;
}


=head2 formCfg

Returns a Configuration Structure for the Booking Entry Form.

=cut

sub parse_time ($self,$str) {
    if ($str !~ /^\s*(\d{1,2}\.\d{1,2}\.\d{4})\s+(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$/) {
            die trm("Expected DD.MM.YYYY HH:MM-HH:MM");
    }
    my $start_ts = eval { 
        localtime->strptime("$1 $2:$3",'%d.%m.%Y %H:%M')->epoch };
    die trm("Error parsing %1","$1 $2:$3") if $@;
    die trm("Can't book in the past!") if $start_ts < time;
    
    my $start = $2*3600+$3*60;
    my $end = $4*3600+$5*60;
    $end += 24*3600 if $end < $start;
    my $duration = $end - $start;
    my $end_ts = $start_ts + $duration;
    my $ret = {
        start_ts => $start_ts,
        start => $start,
        end => $end,
        end_ts => $end_ts,
        duration => $duration,
    };
    # $self->log->debug(dumper $ret);
    return $ret;
}

has formCfg => sub {
    my $self = shift;
    my $db = $self->db;
    my $adm = $self->user->may('admin');
    return [
        $self->config->{type} eq 'edit' ? {
            key => 'booking_id',
            label => trm('Id'),
            widget => 'hiddenText',
            set => {
                readOnly => true,
            },
        } : (),
        $adm
        ? {
            key => 'booking_cbuser',
            label => trm('User'),
            widget => 'selectBox',
            cfg => {
                structure => $db->select(
                    'cbuser',[\"cbuser_id AS key",\"cbuser_login AS title"],undef,'cbuser_login'
                )->hashes->to_array
            },
            validator => sub {
                my $value = shift;
                my $fieldName = shift;
                return trm("Invalid user") unless $value eq $self->user->userId or $self->user->may('admin');
                return;
            },
        }
        :(),
        {
            key => 'booking_room',
            label => trm('Room'),
            widget => 'selectBox',
            cfg => {
                structure => $db->select(
                    'room',[\"room_id AS key",\"room_name AS title"],undef,'room_name'
                )->hashes->to_array
            }
        },
        {
            key => 'booking_time',
            label => trm('Time'),
            widget => 'text',
            set => {
                required => true,
                placeholder => 'DD.MM.YYYY HH:MM-HH:MM',
            },
            validator => sub ($value,$fieldName,$form) {
                my $t = eval { $self->parse_time($value) };
                if ($@) {
                    return $@ if ref $@;
                    die mkerror(8462,$@);
                }

                my $location = $db->query(<<SQL_END,
                SELECT 
                    location_name, 
                    location_open_start,
                    location_open_duration,
                    strftime('%H:%M',location_open_start,'unixepoch') 
                        AS location_open,
                    strftime('%H:%M',location_open_start+location_open_duration,'unixepoch') AS location_close
                FROM location 
                JOIN room ON room_location = location_id 
                WHERE room_id = ?
SQL_END
                $form->{booking_room})->hash;
                my $lstart = $location->{location_open_start};
                my $lend = $lstart + $location->{location_open_duration};
                return trm("Location %1 is only open for booking from %2 to %3",
                    $location->{location_name},
                    $location->{location_open},
                    $location->{location_close}) 
                    if $t->{start} < $lstart or $t->{end} > $lend;
                my @params = (
                    $form->{booking_room},
                    $t->{start_ts},
                    $t->{end_ts}
                );
                my $IGNORE ='';
                if ($form->{booking_id}) {
                    $IGNORE = "AND booking_id <> CAST(? AS INTEGER)";
                    push @params, $form->{booking_id};
                }
                my $overlaps = $db->query(<<SQL_END,@params
                SELECT COUNT(1) AS c
                FROM booking 
                WHERE booking_delete_ts IS NULL 
                AND booking_room = ?
                AND booking_start_ts + booking_duration_s > CAST(? AS INTEGER)
                AND booking_start_ts < CAST(? AS INTEGER)
                $IGNORE
SQL_END
                )->hash;
                return trm("Booking overlaps with %1 existing bookings.",
                    $overlaps->{c}) if $overlaps->{c} > 0;
                return;
            },
        },
        {
            key => 'booking_calendar_tag',
            label => trm('Schedule Text'),
            widget => 'text',
            set => {
                required => true,
                placeholder => trm("Text to show in the schedule")
            },
        },
        {
            key => 'booking_district',
            label => trm('District'),
            widget => 'selectBox',
            cfg => {
                structure => $db->select(
                    'district',[\"district_id AS key",\"district_name AS title"],undef,'district_name'
                )->hashes->to_array
            }
        },
        {
            key => 'booking_agegroup',
            label => trm('Age Group'),
            widget => 'selectBox',
            cfg => {
                structure => $db->select(
                    'agegroup',[\"agegroup_id AS key",\"agegroup_name AS title"],undef,'agegroup_name'
                )->hashes->to_array
            }
        },
        {
            key => 'booking_comment',
            label => trm('Comment'),
            widget => 'textArea',
            set => {
                placeholder => trm("Note for the management")
            },
        },
    ];
};

has mailer => sub ($self) {
    Kuickres::Email->new( app=> $self->app, log=>$self->log );
};

has actionCfg => sub {
    my $self = shift;
    my $type = $self->config->{type} // 'add';
    my $handler = sub {
        my $self = shift;
        my $args = shift;
        my $t = $self->parse_time($args->{booking_time});
        $args->{booking_start_ts} = $t->{start_ts};
        $args->{booking_duration_s} = $t->{duration};
        $args->{booking_create_ts} = time;
        $args->{booking_cbuser} //= $self->user->userId;
        my %USER;
        if (not $self->user->may('admin') and 
            $args->{booking_cbuser} ne $self->user->userId){
            die mkerror(3838,trm("You are not allowed to book in the name of other users."));
            $USER{booking_cbuser} = $self->user->userId;
        }
        my $tx = $self->db->begin;
        my $data = { map { "booking_".$_ => $args->{"booking_".$_} }
            qw( cbuser room start_ts duration_s
            calendar_tag district agegroup comment create_ts) };
        my $ID = $args->{booking_id};
        if ($type eq 'add')  {
            my $res = $self->db->insert('booking',$data);
            $ID = $res->last_insert_id;
        }
        else {
            $self->db->update('booking',$data,{
                booking_id => $args->{booking_id},
                %USER
            });
        }
        my $room = $self->db->query(<<SQL_END,$args->{booking_room})->hash
        SELECT room_name,location_name 
        FROM room JOIN location ON room_location = location_id
        WHERE room_id = ?
SQL_END
        or die mkerror(3874,"Room not found");

        my $userInfo = $self->db->select('cbuser',undef,{
            cbuser_id => $args->{booking_cbuser}
        })->hash or die mkerror(3874,"User not found");
        
        $self->mailer->sendMail({
            to => $userInfo->{cbuser_login},
            from => $self->config->{from},
            template => 'booking',
            args => {
                id => $ID,
                date => strftime(trm('%d.%m.%Y'),localtime($args->{booking_start_ts})),
                location => $room->{location_name},
                room => $room->{room_name},
                time => $args->{booking_time},
                accesscode => $userInfo->{cbuser_pin},
                email => $userInfo->{cbuser_login},
            }
        });
        $tx->commit;
        return {
            action => 'dataSaved'
        };
    };

    return [
        {
            label => $type eq 'edit'
               ? trm('Save Changes')
               : trm('Add Booking'),
            action => 'submit',
            key => 'save',
            actionHandler => $handler
        }
    ];
};

has grammar => sub {
    my $self = shift;
    $self->mergeGrammar(
        $self->SUPER::grammar,
        {
            _vars => [ qw(type) ],
            type => {
                _doc => 'type of form to show: edit, add',
                _re => '(edit|add)'
            },
        },
    );
};

sub getAllFieldValues {
    my $self = shift;
    my $args = shift;
    return {} if $self->config->{type} ne 'edit';
    my $id = $args->{selection}{booking_id};
    return {} unless $id;
    my $WHERE = {
        booking_id => $id
    };
    if (not $self->user->may('admin')) {
        $WHERE->{booking_cbuser} = $self->user->userId
    }
    return $self->db->select('booking',['*',
        \"strftime('%d.%m.%Y %H:%M-',booking_start_ts,'unixepoch','localtime')
        || strftime('%H:%M',booking_start_ts+booking_duration_s,'unixepoch','localtime')
        AS booking_time"],
        $WHERE
    )->hash;
}

has grammar => sub {
    my $self = shift;
    $self->mergeGrammar(
        $self->SUPER::grammar,
        {
            _vars => [ qw(from ) ],
            _mandatory => [ qw(from) ],
            from => {
                _doc => 'sender for mails',
            },
        },
    );
};

1;
__END__

=head1 AUTHOR

S<Tobias Oetiker E<lt>tobi@oetiker.chE<gt>>

=head1 HISTORY

 2020-02-21 oetiker 0.0 first version

=cut
