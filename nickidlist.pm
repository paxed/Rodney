package NickIdList;

use strict;
use warnings;
use diagnostics;

use DBI;

sub new {
    my $class = shift;
    my %args  = @_;
    return bless \%args, $class;
}

sub is_identified {
    my $self = shift;
    my $nick = shift;
    return 1 if ( grep {$_ eq $nick} @{$self->{'idlist'}} );
    return 0;
}

sub get_identified_nicks {
    my $self = shift;
    return join(", ", @{$self->{'idlist'}} );
}

sub nick_identify {
    my $self = shift;
    my $nick = shift;
    push(@{$self->{'idlist'}}, $nick);
}

sub nick_deidentify {
    my $self = shift;
    my $nick = shift;
    my $a;
    my $counter = 0;

    foreach $a (@{$self->{'idlist'}}) {
	if ($a eq $nick) {
	    splice(@{$self->{'idlist'}}, $counter, 1);
	    return;
	}
	$counter++;
    }
}


1;

__END__
