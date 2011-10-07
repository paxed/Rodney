package SeenDB;

#
#sqlite3 "seen.db" "create table seendb (name text primary key not null, seentext text not null, seentime timestamp not null)"
#

use strict;
use warnings;
use diagnostics;

use DBI;

do "librodney.pm";

# Set us up the bomb
# my $seendb = SeenDB->new();
sub new {
    my $class = shift;
    my %args  = @_;
    return bless \%args, $class;
}

sub db_connect {
    my $self = shift;

    return if (defined $self->{'disabled'} && ($self->{'disabled'} == 1));

    if (!($self->{'dbh'} = DBI->connect("dbi:SQLite:dbname=".$self->{'dbfile'},"","",{AutoCommit => 1, PrintError => 1}))) {
	$self->{'disabled'} = 1;
	print "Seen db disabled, could not connect to database.\n";
    } else {
	$self->{'disabled'} = 0;
    }
}

sub db_disconnect {
    my $self = shift;
    return if ($self->{'disabled'});
#    $self->{'dbh'}->commit();
    $self->{'dbh'}->disconnect();
}


# $self->init(FILENAME);
sub init {
    my $self = shift;
    my $seenfile = shift || $self->{'dbfile'};

    $self->{'dbfile'} = $seenfile if (!$self->{'dbfile'});
}

# $self->sync();
sub sync {
}

# $self->db_connect();
# $self->seen_updatenick($nick, $time, $text);
# $self->db_disconnect();
sub seen_updatenick {
    my ($self, $nick, $time, $text) = @_;

    return if ($self->{'disabled'});

    my $dbh = $self->{'dbh'};

    my $sth = $dbh->prepare("SELECT count(*) FROM seendb WHERE name=".$dbh->quote($nick));
    if ($dbh->err()) { print "$DBI::errstr\n"; return; }
    $sth->execute();

    my $rowcnt = $sth->fetchrow_hashref();

    if ($rowcnt->{'count(*)'} > 0) {
	$sth = $dbh->prepare("UPDATE seendb SET seentext=".$dbh->quote($text).
			     ", seentime=".$dbh->quote($time)." WHERE name=".$dbh->quote($nick));
    } else {
	$sth = $dbh->prepare("INSERT INTO seendb (name,seentext,seentime) VALUES (".
			     $dbh->quote($nick).", ".
			     $dbh->quote($text).", ".
			     $dbh->quote($time).")");
    }
    if ($dbh->err()) { print "$DBI::errstr\n"; return; }
    $sth->execute();
}


# $self->seen_setnicks($nicks, $channel);
sub seen_setnicks {
    my $self = shift;
    my $nicklist = shift;
    my $channel = shift || $self->{'channel'};
    my $a;
    my @nlist = (split / /, $nicklist);

    print "->".$nicklist."<-\n";
    print "--".$channel."--\n";

    $channel =~ s/^[^a-zA-Z]*/#/;

    my $time = time();
    my $text = "was on $channel when I joined";

    $self->db_connect();

    foreach $a (@nlist) {
	$a =~ s/^@//;
	$a =~ tr/A-Z/a-z/;
	$self->seen_updatenick($a, $time, $text);
    }

    $self->db_disconnect();
}


# $self->seen_log($nick, $action);
sub seen_log {
    my $self = shift;
    my $nick = shift;
    my $act = shift;

    $nick =~ s/^@//;
    $nick =~ tr/A-Z/a-z/;
    my $date = time();

    $self->db_connect();
    $self->seen_updatenick($nick, $date, $act);
    $self->db_disconnect();
}


# $self->seen_get($nick);
sub seen_get {
    my $self = shift;
    my $nick = shift;
    $nick =~ s/^@//;
    $nick =~ tr/A-Z/a-z/;

    my $dbdata;

    my $retstr = "";

    return "Seen DB disabled." if ($self->{'disabled'});

    $self->db_connect();

    my $dbh = $self->{'dbh'};
    my $sth = $dbh->prepare("SELECT seentime,seentext FROM seendb WHERE name=".$dbh->quote($nick));
    if ($dbh->err()) { print "$DBI::errstr\n"; return; }
    $sth->execute();

    while ($dbdata = $sth->fetchrow_hashref()) {
	my $timediff = time() - $dbdata->{'seentime'};
	my $time = time_diff($timediff, 1) if ($timediff > 59);

	my $act = $dbdata->{'seentext'};

	if ($time && (length($time) > 0)) {
	    $time = ", ".$time." ago";
	    $retstr = $nick.' '.$act.$time;
	} else {
	    $retstr = $nick.' just '.$act;
	}
    }

    $self->db_disconnect();
    return $retstr;
}


1;

__END__
