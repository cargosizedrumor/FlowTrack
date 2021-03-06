use strict;
use warnings;
use Log::Log4perl qw(get_logger);
use autodie;

use Test::More tests => 16;
use Data::Dumper;
use FT::Schema;

use vars qw($DB_TEST_FILE);

# Assumes you have flow tools in /opt/local/bin or /usr/bin

my $DB_TEST_FILE = "FT_TEST.sqlite";

BEGIN
{
    use_ok('FT::FlowTrack');
}

test_main();

sub test_main
{
    unlink("/tmp/$DB_TEST_FILE") if ( -e "/tmp/$DB_TEST_FILE" );
    object_tests();
    db_creation();
}

#
# Object Creation
# Make sure custom settings and default settings work.
#
# Make sure the schema definition stuff passes through cleanly
#
sub object_tests
{
    #
    # object Creation, using defaults
    #

    # Custom Values
    my $ft_custom = FT::FlowTrack->new( "./blah", 1, "flowtrack.sqlite" );
    ok( $ft_custom->{location} eq "./blah", "custom location" );
    ok( $ft_custom->{debug} == 1, "custom debug setting" );
    ok( $ft_custom->{dbname} eq "flowtrack.sqlite", "custom DB name" );
    unlink("./blah/flowtrack.sqlite");
    rmdir("./blah");

    # Default Values
    my $ft_default = FT::FlowTrack->new();
    ok( $ft_default->{location} eq "Data", "default location" );
    ok( $ft_default->{debug} == 0, "default debug setting" );
    ok( $ft_default->{dbname} eq "FlowTrack.sqlite", "default DB name" );

    # make sure we get back a well known table name
    my $tables = $ft_default->get_tables();
    ok( grep( /raw_flow/, @$tables ), "Schema List" );

    # Do a basic schema structure test
    my $table_def = $ft_default->get_table("raw_flow");
    ok( $table_def->[0]{name} eq "flow_id", "Schema Structure" );

    my $create_sql = $ft_default->get_create_sql("raw_flow");
    ok( $create_sql ~~ /CREATE.*fl_time.*/, "Create statement generation" );
}

#
# Check Database Creation routines
#
sub db_creation
{

    #
    # DB Creation
    #
    # We'll use $dbh and $db_creat for several areas of testing
    #

    my $db_creat = FT::FlowTrack->new( "/tmp", 1, $DB_TEST_FILE );

    my $dbh = $db_creat->_initDB();
    ok( -e "/tmp/$DB_TEST_FILE", "database file exists" );
    is_deeply( $dbh, $db_creat->{dbh}, "object db handle compare" );
    is_deeply( $db_creat->{dbh}, $db_creat->{db_connection_pool}{$$}, "connection pool object storage" );

    #
    # Table creation
    #
    ok( $db_creat->_createTables(), "Table Creation" );

    ok( $db_creat->_createTables(), "Table creation (re-entrant test)" );

    #
    # Check to make sure tables were created
    #
    my @table_list = $dbh->tables();
    ok( grep( /raw_flow/, @table_list ), "raw_flow created" );
}

END
{
    #cleanup
}

