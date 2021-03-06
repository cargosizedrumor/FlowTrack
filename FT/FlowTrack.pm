package FT::FlowTrack;

use feature ':5.10';
use Carp;
use strict;
use warnings;
use Log::Log4perl qw(get_logger);

use DBI;
use Data::Dumper;
use FT::Configuration;
use FT::Schema;
use File::Path qw(make_path);
use Net::IP;
use Socket;    # For inet_ntoa
use vars '$AUTOLOAD';

#
# Constructor
#
# Takes ("directory for db files",<debug>,"db file name")
#
# Sets defaults if needed
#
sub new
{
    my $class = shift;
    my $self  = {};

    ( $self->{location}, $self->{debug}, $self->{dbname}, $self->{internal_network} ) = @_;

    # ensure we have some defaults
    $self->{dbname}           ||= "FlowTrack.sqlite";
    $self->{location}         ||= "Data";
    $self->{debug}            ||= 0;
    $self->{internal_network} ||= "192.168.1.0/24";

    # Setup space for connection pools and the database handle
    $self->{db_connection_pool} = {};
    $self->{dbh}                = {};

    bless( $self, $class );

    $self->{dbh} = $self->_initDB();
    $self->_createTables();

    return $self;
}

#
# Handles storing flows to the database
#
# Takes an array of flow records (similar to how Net::Flow combines things)
# But the array covers the entire time window, not just a single packet.
# Not doing anyting at the packet leve on this side.
#
sub storeFlow
{
    my ( $self, $flows ) = @_;
    my $insert_struct;
    my $insert_queue;
    my $logger        = get_logger();
    my $batch_counter = 0;
    my $total_saved   = 0;
    my $batch_size    = 100;

    # Don't do anything if we don't have flows
    return unless ( defined($flows) );

    my $dbh = $self->_initDB();

    my $sql =
      "INSERT INTO raw_flow ( fl_time, src_ip, dst_ip, src_port, dst_port, bytes, packets ) VALUES (?,?,?,?,?,?,?)";

    my $sth = $dbh->prepare($sql)
      or croak( "Coudln't preapre SQL: " . $dbh->errstr() );

    foreach my $flow_rec ( @{$flows} )
    {

        # creat a datastructure that looks like this
        # $insert_struct->[batch]{field_name1} = [ array of all values for field_name1 ]
        # $insert_struct->[batch]{field_name2} = [ array of all values for field_name2 ]
        #
        # To be used by execute array
        push( @{ $insert_struct->[$batch_counter]{$_} }, $flow_rec->{$_} ) for keys %$flow_rec;

        $insert_queue++;
        if ( $insert_queue > $batch_size )
        {
            $batch_counter++;
            $insert_queue = 0;
        }
    }

    foreach my $batch (@$insert_struct)
    {
        my @tuple_status;
        my $rows_saved =
          $sth->execute_array(
                               { ArrayTupleStatus => \@tuple_status },
                               $batch->{fl_time},  $batch->{src_ip}, $batch->{dst_ip}, $batch->{src_port},
                               $batch->{dst_port}, $batch->{bytes},  $batch->{packets}
          ) or croak( print Dumper( \@tuple_status ) . "\n trying to store flow in DB DBI: " . $dbh->errstr() );

        $total_saved += $rows_saved;
    }

    $logger->debug("Saved: $total_saved");
    return;
}

#
# Handle's building the reports (graphs, html, etc)
#
sub runReports
{
    my $self = shift();

    return;
}

#
# Gets flows for the last x minutes
#
# returns an array of flows for the last x minutes
sub getFlowsForLast
{
    my $self    = shift();
    my ($range) = @_;
    my $now     = time;

    my $start_time;
    my $end_time;

    $start_time = $now - ( $range * 60 );
    $end_time = $now;

    return $self->getFlowsInTimeRange( $start_time, $end_time );
}

#
# Gets flows in the specified time range
#
sub getFlowsInTimeRange
{
    my $self = shift();
    my ( $start_time, $end_time ) = @_;
    my $dbh = $self->_initDB();
    my $ret_list;

    my $sql = "SELECT * FROM raw_flow WHERE fl_time BETWEEN ? AND ? ORDER BY fl_time";
    my $sth = $dbh->prepare($sql);
    $sth->execute( $start_time, $end_time );

    while ( my $ref = $sth->fetchrow_hashref )
    {
        push @$ret_list, $self->processFlowRecord($ref);
    }

    return $ret_list;
}

#
# Return the list of ingress flows for the last minute
#
sub getIngressFlowsForLast
{
    my $self = shift();
    my ($duration) = @_;

    return $self->getIngressFlowsInTimeRange( time - ( $duration * 60 ), time );

}

#
# return ingress flows for the given time range
#
sub getIngressFlowsInTimeRange
{
    my $self = shift();
    my ( $start_time, $end_time ) = @_;
    my $logger = get_logger();
    my $dbh    = $self->_initDB();
    my $ret_list;

    my $internal_network = Net::IP->new( $self->{internal_network} );

    my $sql = qq{
        SELECT * FROM raw_flow WHERE 
        fl_time >= ? AND fl_time <= ?
        AND
        src_ip NOT BETWEEN ? AND ?
        AND
        dst_ip BETWEEN ? AND ?
    };

    my $sth = $dbh->prepare($sql) or $logger->fatal( "failed to prepare:" . $DBI::errstr );

    $sth->execute( $start_time, $end_time,
                   $internal_network->intip(),
                   $internal_network->last_int(),
                   $internal_network->intip(),
                   $internal_network->last_int() )
      or $logger->fatal( "failed executing $sql:" . $DBI::errstr );

    while ( my $ref = $sth->fetchrow_hashref )
    {
        push @$ret_list, $self->processFlowRecord($ref);
    }

    return $ret_list;
}

#
# Return the list of egress flows for the last minute
#
sub getEgressFlowsForLast
{
    my $self = shift();
    my ($duration) = @_;

    return getEgressFlowsInTimeRange( time - ( $duration * 60 ), time );
}

#
# Returns a list of egress flows in the provided time range
#
sub getEgressFlowsInTimeRange
{
    my $self = shift();
    my ( $start_time, $end_time ) = @_;
    my $dbh    = $self->_initDB();
    my $logger = get_logger();
    my $ret_list;

    $logger = get_logger();

    my $internal_network = Net::IP->new( $self->{internal_network} );

    my $sql = qq{
        SELECT * FROM raw_flow WHERE 
        fl_time >= ? AND fl_time <= ?
        AND
        src_ip BETWEEN ? AND ?
        AND
        dst_ip NOT BETWEEN ? AND ?
    };

    my $sth = $dbh->prepare($sql) or $logger->fatal( "failed to prepare:" . $DBI::errstr );

    $sth->execute( $start_time, $end_time,
                   $internal_network->intip(),
                   $internal_network->last_int(),
                   $internal_network->intip(),
                   $internal_network->last_int() )
      or $logger->fatal( "failed executing $sql:" . $DBI::errstr );

    while ( my $ref = $sth->fetchrow_hashref )
    {
        push @$ret_list, $self->processFlowRecord($ref);
    }

    return $ret_list;
}

sub purgeData
{
    my $self   = shift();
    my $dbh    = $self->_initDB();
    my $logger = get_logger();

    my $conf = FT::Configuration::getConf();

    my $watermark    = time - $conf->{purge_interval};
    my $rows_deleted = 0;

    my $sql = qq{
        DELETE FROM raw_flow WHERE fl_time < ?
    };

    my $sth = $dbh->prepare($sql) or $logger->fatal( "failed to prepare:" . $DBI::errstr );

    $rows_deleted = $sth->execute($watermark) or $logger->fatal( "Delete failed: " . $DBI::errstr );

    $logger->debug("Purged: $rows_deleted") if ( $rows_deleted > 0 );

    return;
}

#
# This routine cleans up a single FlowRecord (select * from the raw_flow table)
# takes a hashref representing a single record from the raw_flow table;
# returns the same record with some data conversion done (Net::IP Objects, converted port #s etc)
sub processFlowRecord
{
    my $self = shift();
    my ($flow_record) = @_;
    my $ret_struct;

    foreach my $key ( keys %{$flow_record} )
    {

        # Do the data conversion
        given ($key)
        {

            #IP Addresses
            # Want to leave the original address there as well, in case we can't
            # get to the object
            when (/_ip$/)
            {
                $ret_struct->{$key} = $flow_record->{$key};
                $ret_struct->{ $key . "_obj" } =
                  Net::IP->new( join( '.', unpack( 'C4', pack( 'N', $flow_record->{$key} ) ) ) );
            }

            # if we don't do anything else, just copy the data
            default { $ret_struct->{$key} = $flow_record->{$key} }

        }
    }

    return $ret_struct;

}

#
# "Private" methods below.  Not stopping folks from calling these, but they're really not interesting
#

#
# gets a db handle
#
# Returns one if we already have a dbh for the current process, otherwise it connects to
# the DB, stores the handle in the object, and returns the dbh
#
# takes self
# croaks on error
#
sub _initDB
{
    my ($self) = @_;
    my $logger = get_logger();

    my $db_name = $self->{dbname};

    if ( defined( $self->{db_connection_pool}{$$} ) )
    {
        $self->{dbh} = $self->{db_connection_pool}{$$};
        return $self->{dbh};
    }
    else
    {

        $self->_checkDirs();

        my $dbfile = $self->{location} . "/" . $db_name;

        my $dbh = DBI->connect( "dbi:SQLite:dbname=$dbfile", "", "" );

        if ( defined($dbh) )
        {
            $self->{dbh} = $dbh;
            $self->{db_connection_pool}{$$} = $dbh;
            return $dbh;
        }
        else
        {
            $logger->fatal( "_initDB failed: $dbfile" . $DBI::errstr );
            croak;
        }
    }
}

#
# Creates the needed tables
#   raw_flow
#
# Right now this is very simple.  It may need to get more complicated as we do more with
# aggregation etc.  We'll see.
#
# Takes nothing
# croaks on error
#
sub _createTables
{
    my ($self) = @_;
    my $tables = [qw/raw_flow/];
    my $logger = get_logger();

    foreach my $table (@$tables)
    {
        if ( !$self->_tableExists($table) )
        {
            my $dbh = $self->_initDB();
            my $sql = $self->get_create_sql($table);

            if ( !defined($sql) || $sql eq "" )
            {
                $logger->fatal("Couldn't create SQL statement for $table");
                die;
            }

            my $sth = $dbh->prepare($sql);
            my $rv  = $sth->execute();

            if ( !defined($rv) )
            {
                $logger->fatal($DBI::errstr);
                die;
            }
        }
    }

    return 1;
}

# returns 1 if the named table exists
sub _tableExists
{
    my $self = shift();
    my ($table_name) = @_;

    my $dbh = $self->_initDB();

    my @tables = $dbh->tables();

    return grep { /$table_name/ } @tables;
}

# Check to make sure the data directory exists, if not, create it.
sub _checkDirs
{
    my $self = shift();
    my $err;

    unless ( -d $self->{location} )
    {

        # make path handles error checking
        make_path( $self->{location} );
    }

    # Make sure the directory exists
    croak( $self->{location} . " strangely absent" )
      unless ( -d $self->{location} );

    return;
}

#
# So we can passthrough calls to the Schema routines
#
# Mainly to get the schema handling code out of this package.
#
sub AUTOLOAD
{

    # Need to shift off self.  Dont't think that FT::Schema is going to need it
    # but I'm not sure.  Either way, we want it off of @_;
    my $self = shift();

    given ($AUTOLOAD)
    {
        when (/get_tables/)
        {
            return FT::Schema::get_tables(@_);
        }

        when (/get_table/)
        {
            return FT::Schema::get_table(@_);
        }

        when (/get_create_sql/)
        {
            return FT::Schema::get_create_sql(@_);
        }

        # mainly to stop the autoloader from bitching
        when (/DESTROY/)
        {
            return;
        }

    }

    die "Couldn't find $AUTOLOAD";
}
1;
__END__

=head1 FlowTrack

Routines surrounding the processing of the flowtrack data.

Only the public methods

=head2 new

FlowTrack->new(<db directory>,<logging 1 == on>, <dbname>);

FlowTrack->storeFlow($flow_list);
