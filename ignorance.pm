package Ignorance;

use strict;
use warnings;
use diagnostics;

use DBI;

do "librodney.pm";

sub new {
    my $class = shift;
    my %args  = @_;
    return bless \%args, $class;
}

# $self->init(FILENAME);
sub init {
    my $self = shift;
    my $seenfile = shift || $self->{'dbfile'};

    $self->{'dbfile'} = $seenfile if (!$self->{'dbfile'});
    @{$self->{'ignorance'}} = ();
}

sub is_ignored {
    my $self = shift;
    my $who = shift;
    my $line = shift;

    foreach my $a (@{$self->{'ignorance'}}) {
	my @b = ( split /\t/, $a );
	return 1 if (($who =~ m/\l$b[0]\Q/i) && ($line =~ m/\l$b[1]\Q/i));
    }
    return 0;
}

sub count {
    my $self = shift;
    my $len = @{$self->{'ignorance'}};
    return int($len);
}

sub get_nth {
    my $self = shift;
    my $n = shift || 0;
    return @{$self->{'ignorance'}}[$n] if ($n >= 0 && $n < scalar(@{$self->{'ignorance'}}));
    return '';
}

sub rm_nth {
    my $self = shift;
    my $n = shift || 0;
    splice(@{$self->{'ignorance'}}, $n, 1) if ($n >= 0 && $n < scalar(@{$self->{'ignorance'}}));
}

sub add {
    my $self = shift;
    my $a = shift || "";
    push(@{$self->{'ignorance'}}, $a) if ($a =~ m/\t/);
}

sub save {
    my $self = shift;
    my $fname = $self->{'dbfile'};
    open(IGNWRITE, ">", $fname) || return;
    foreach my $a (@{$self->{'ignorance'}}) {
	print IGNWRITE "$a\n";
    }
    close(IGNWRITE);
}

sub load {
    my $self = shift;
    my $fname = $self->{'dbfile'};
    if (open(IGNREAD, $fname)) {
	@{$self->{'ignorance'}} = ();
	while (<IGNREAD>) {
	    my $a = $_;
	    chop($a);
	    push(@{$self->{'ignorance'}}, $a) if ($a =~ m/^(.+)\t(.+)$/);
	}
    } else {
	debugprint("can't read $fname");
    }
}



1;

__END__
