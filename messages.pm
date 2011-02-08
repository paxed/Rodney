package Messages;

#
#sqlite3 "messages.db" "create table messagesdb (name text not null, sender text not null, msg text not null, lefttime timestamp not null, notified boolean false)"
#

use strict;
use warnings;
use diagnostics;

use DBI;

do "librodney.pm";

# Set us up the bomb
# my $messagesdb = Messages->new();
sub new {
    my $class = shift;
    my %args  = @_;
    return bless \%args, $class;
}

sub db_connect {
    my $self = shift;
    $self->{'dbh'} = DBI->connect("dbi:SQLite:dbname=".$self->{'dbfile'},"","",{AutoCommit => 1, PrintError => 1});
}

sub db_disconnect {
    my $self = shift;
#    $self->{'dbh'}->commit();
    $self->{'dbh'}->disconnect();
}


# $self->init(FILENAME);
sub init {
    my $self = shift;
    my $seenfile = shift || $self->{'dbfile'};

    $self->{'dbfile'} = $seenfile if (!$self->{'dbfile'});
}


# $self->have_messages($nick);
sub have_messages {
    my ($self, $nick) = @_;

    $self->db_connect();

    $nick =~ tr/A-Z/a-z/;

    my $dbh = $self->{'dbh'};

    my $sth = $dbh->prepare("SELECT count(*) FROM messagesdb WHERE name=".$dbh->quote($nick)." and notified='false'");
    if ($dbh->err()) { print "$DBI::errstr\n"; return 0; }
    $sth->execute();

    my $rowcnt = $sth->fetchrow_hashref();

    $sth = $dbh->prepare("UPDATE messagesdb SET notified='true' WHERE name=".$dbh->quote($nick)." and notified='false'");
    if ($dbh->err()) { print "$DBI::errstr\n"; } else {
	$sth->execute();
    }

    $self->db_disconnect();

    return $rowcnt->{'count(*)'};
}

# $self->leave_message($tonick, $fromnick, $msg);
sub leave_message {
    my ($self, $tonick, $fromnick, $msg) = @_;

    $tonick =~ tr/A-Z/a-z/;

    my $time = time();

    $self->db_connect();

    my $dbh = $self->{'dbh'};

    my $sth = $dbh->prepare("INSERT INTO messagesdb (name,sender,msg,lefttime,notified) VALUES (".
			    $dbh->quote($tonick).", ".
			    $dbh->quote($fromnick).", ".
			    $dbh->quote($msg).", ".
			    $dbh->quote($time).", 'false')");

    if ($dbh->err()) { print "$DBI::errstr\n"; return 0; }
    $sth->execute();

    $self->db_disconnect();
    return 1;
}


# $self->get_messages($nick);
sub get_messages {
    my ($self, $nick) = @_;

    $self->db_connect();

    $nick =~ tr/A-Z/a-z/;

    my $dbh = $self->{'dbh'};

    my $sth = $dbh->prepare("SELECT sender,msg,lefttime FROM messagesdb where name=".$dbh->quote($nick)." ORDER BY lefttime ASC");

    if ($dbh->err()) { print "$DBI::errstr\n"; return; }
    $sth->execute();

    my @ret;

    while (my $dbdata = $sth->fetchrow_hashref()) {
	my $timediff = time() - $dbdata->{'lefttime'};
	my $time = time_diff($timediff, 1) if ($timediff > 59);

	my $act = $dbdata->{'msg'};

	my $fromnick = $dbdata->{'sender'};

	if ($time && (length($time) > 0)) {
	    $time = " (".$time." ago)";
	} else {
	    $time = "";
	}
	push(@ret, $fromnick." said".$time.": ".$act);
    }

    $sth = $dbh->prepare("DELETE FROM messagesdb WHERE name=".$dbh->quote($nick));
    if ($dbh->err()) { print "$DBI::errstr\n"; } else {
	$sth->execute();
    }

    $self->db_disconnect();
    return join("\n", @ret);
}


1;

__END__
