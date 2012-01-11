package LearnDB;

use strict;
use warnings;
use diagnostics;

# hash values used:
# dbfile	the file name where to read from / write to
# db		the db hash
# dbchanged	has the db been changed since last sync?
# searchlimit	max. # of entries to search can return
# ncontribs	show this many contributor names in debug info


# Set us up the bomb
# my $learndb = LearbDB->new();
sub new {
    my $class = shift;
    my %args  = @_;
    return bless \%args, $class;
}


# $self->init(FILENAME);
sub init {
    my $self = shift;
    my $learnfile = shift || $self->{'dbfile'};

    if (open(LEARNFILE, $learnfile)) {
	while(<LEARNFILE>) {
	    my ($user,$term,$def) = /^(\S+)\t(\S+)\t(.*)$/;
	    if ($term) {
		push @{$self->{'db'}{$term}}, [$user, $def];
	    }
	}
	$self->{'dbfile'} = $learnfile if (!$self->{'dbfile'});
    } else {
	print "Cannot open learndb file $learnfile.\n";
    }
    $self->{'dbchanged'} = 0;
}


# $self->sync();
sub sync {
    my $self = shift;
    my $dbfile = shift || $self->{'dbfile'};
    my $a;

    if (!($self->{'dbchanged'})) { return; }

    open(LEARNWRITE, ">" . $dbfile) || die("can't open $dbfile for write");
    while (my ($term, $termdefs) = each %{$self->{'db'}}) {
	print LEARNWRITE "$_->[0]\t$term\t$_->[1]\n" for @$termdefs;
    }
    close(LEARNWRITE);

    $self->{'dbchanged'} = 0;

    print "Synched $dbfile\n";
}


# $self->add($term, $user, $define);
sub add {
    my $self = shift;
    my $term = lc shift;
    my $user = shift;
    my $def = shift;
    my @return;

    if ($term && $user && $def) {
	push @{$self->{'db'}{$term}}, [$user, $def];
	push (@return, "Term $term\[" . (0+@{$self->{'db'}{$term}}) . "] successfully added.");
	$self->{'dbchanged'} = 1;
    }
    return @return;
}


# $self->del($term [, $num]);
sub del {
    my $self = shift;
    my $term = lc shift;
    my $num = shift || 1;
    my $a;
    my $counter = 0;
    my $found = 0;
    my @return;

    if (!exists $self->{'db'}{$term}) {
	@return = "I can't seem to find '$term' in my dictionary.";
    }
    elsif ($num < 1 || $num > @{$self->{'db'}{$term}}) {
	@return = "I don't seem to have an entry for $term\[$num\]."
    } else {
	my $removed = $self->{'db'}{$term}[$num-1][1];
	splice @{$self->{'db'}{$term}}, $num-1, 1;
	$self->{'dbchanged'} = 1;
	@return = "Removed $term\[$num\]: $removed";
    }
    return @return;
}

# $self->swap("foo", N, "bar", M);
# $self->swap("foo", '', "bar", '') completely exchanges the two terms.
sub swap {
    my $self = shift;
    my $terma = lc shift;
    my $terman = shift;
    my $termb = lc shift;
    my $termbn = shift;
    my $counter = 0;
    my @return;
    my $a;
    my $c;
    my $ok = 0;
    my $wildcard = ($terman eq '' && $termbn eq '');

    return @return if (($terma eq $termb) && ($terman == $termbn));

    if (!exists $self->{'db'}{$terma}) {
    	@return = "I can't seem to find '$terma' in my dictionary.";
	return @return;
    }
    if (!exists $self->{'db'}{$termb}) {
	@return = "I can't seem to find '$termb' in my dictionary.";
	return @return;
    }
    if (!$wildcard && ($terman < 1 || $terman > @{$self->{'db'}{$terma}}) ) {
	@return = "Someone must have torn the page with $terma\[$terman] out of my notebook.";
	return @return;
    }
    if (!$wildcard && ($termbn < 1 || $termbn > @{$self->{'db'}{$termb}}) ) {
	my @terms = keys %{$self->{'db'}};
	my $otherterm = $terms[rand @terms];
	@return = "I don't see $termb\[$termbn]. Perhaps you mean ".
	    $otherterm . "[". (1+int rand( @{$self->{'db'}{$otherterm}} )). "]?";
	return @return;
    }
    # lo and behold, it seems that these two both exist.
    if ($wildcard) {
	# You won't see this technique in any C++ program ;)
	($self->{'db'}{$terma}, $self->{'db'}{$termb}) = ($self->{'db'}{$termb}, $self->{'db'}{$terma});
	$self->{'dbchanged'} = 1;
	@return = "Terms '$terma' and '$termb' exchanged.";
    }
    else {
	# swapping two individual definitions
	( $self->{'db'}{$terma}[$terman - 1],
	  $self->{'db'}{$termb}[$termbn - 1] ) =	( $self->{'db'}{$termb}[$termbn - 1],
						  $self->{'db'}{$terma}[$terman - 1] );
	$self->{'dbchanged'} = 1;
	@return = "Swapped definitions: $terma\[$terman] <-> $termb\[$termbn]";
    }

    return @return;
}

# !learn edit todo[1] s/foo/bar/g
# $self->edit("todo", 1, "foo", "bar", "g");
sub edit {
    my $self = shift;
    my $term = lc shift;
    my $termno = shift;
    my $edita = shift;
    my $editb = shift || "";
    my $opts = shift || "";
    my $counter = 0;
    my @return;
    my $a;

    return @return if ($edita eq $editb);

    if (!exists $self->{'db'}{$term}) {
    	@return = "I can't seem to find '$term' in my dictionary.";
	return @return;
    }
    if ($termno < 1 || $termno > @{$self->{'db'}{$term}}) {
	@return = "Someone must have torn the page with $term\[$termno] out of my notebook.";
	return @return;
    }

    my $oldtext = $self->{'db'}{$term}[$termno-1][1];

    if (index($opts, 'g') >= 0 && index($opts, 'i') >= 0) {
	# s///gi
	$self->{'db'}{$term}[$termno-1][1] =~ s/$edita/$editb/gi;
    } elsif (index($opts, 'g') >= 0) {
	# s///g
	$self->{'db'}{$term}[$termno-1][1] =~ s/$edita/$editb/g;
    } elsif (index($opts, 'i') >= 0) {
	# s///i
	$self->{'db'}{$term}[$termno-1][1] =~ s/$edita/$editb/i;
    } else {
	# s///
	$self->{'db'}{$term}[$termno-1][1] =~ s/$edita/$editb/;
    }

    if ($oldtext eq $self->{'db'}{$term}[$termno-1][1]) {
	push (@return, 'Nothing changed');
    } else {
	push (@return, "$term\[$termno]: $self->{'db'}{$term}[$termno-1][1]");
	$self->{'dbchanged'} = 1;
    }

    return @return;
}


# $self->search($for, \$error);
sub search {
    my $self = shift;
    my $searchedfor = shift;
    my $errvar = shift;
    my $term;
    my @return;
    my $searchlimit = $self->{'searchlimit'} || 20;

    local $" = ' ';	# space

    # multiword search -- 7/19/2004 4:39PM by Stevie-O
    $term = join('.*', map {quotemeta} split ' ', $searchedfor);

    my @sortresults = sort
	# find all the things that match.  Don't get too confused by all the $_'s.
	grep { !$self->is_redirect($_) } # don't include see-also definitions
	grep { $_ =~ /$term/i || 
		   grep { $_->[1] =~ /$term/i } @{$self->{'db'}{$_}} } keys %{$self->{'db'}};

    # now @sortresults is a list of every single term with something matching the regex.

    if (@sortresults > $searchlimit) {
    	$$errvar = 1;
	push(@return, scalar(@sortresults)." results for $searchedfor. Please narrow your search.");
    } elsif (@sortresults == 1) {
	return $self->query($sortresults[0]);
    } elsif (@sortresults) {
    	$$errvar = 1;
	push(@return, scalar(@sortresults)." results for $searchedfor: @sortresults");
    } else {
    	$$errvar = 1;
	push(@return,"No results found for $searchedfor.");
    }
    return @return;
}


# $self->info($term);
sub info {
    my $self = shift;
    my $term = lc shift;
    my $textreturn = '';
    my $counter = 0;
    my @return;
    my $a;

    if (exists $self->{'db'}{$term}) {
	@return = "$term has contributions by: ".
	    join ' ', map "[".($_+1)."]$self->{'db'}{$term}[$_][0]", 0..$#{$self->{'db'}{$term}};
    } else {
	push(@return,"$term not found in dictionary.");
    }

    return @return;
}


# $self->is_redirect($term);
# returns undef if the specified term is NOT a redirect, otherwise the term name.
sub is_redirect {
    my $self = shift;
    my $term = shift;
    # allow a term entry or a term name to be specified
    unless (ref $term) { $term = $self->{'db'}{lc $term} };
    return unless $term;

    if (@$term == 1 && $term->[0][1] =~ /^see \{(.*)\}$/i) {
	$term = lc $1;
	$term =~ s/\s+/_/g;
	return $term;
    }
    return ();
}


# $self->query($term,$depth);
sub query {
    my ($self, $term, $depth) = @_;
    $term = lc $term;
    $depth ||= 0; # undef => 0
    my @return;
    my $nopreprocess = 0;

    # use ?< ~term to get that exact term
    # make special case for just plain '~'
    if ($term ne '~' && $term =~ /^~/) {
	$nopreprocess = 1;
	substr($term, 0, 1) = '';
    }

    return unless exists $self->{'db'}{$term};

    my $termdefs = $self->{'db'}{$term};

    unless ($nopreprocess) {
        # Preprocess it a bit.
	if (@$termdefs == 1) {
	    my $redir;
	    # check for 'see-instead' commands,
	    # as a single definition consisting of 'see {new term here}'
	    # a recursion counter prevents people from creating infinite loops
	    if ($depth < 5 && defined($redir = $self->is_redirect($termdefs))) {
		# This can return somewhat incorrect results if
		@return = $self->query($redir, $depth + 1);
		if (@return && $return[0] !~ /^Redirected to/) {
		    unshift @return, "Redirected to $redir";
		}
		return @return;
	    }
	}
    }
    @return = map "$term\[".($_+1)."/".($#$termdefs+1)."]: $self->{'db'}{$term}[$_][1]", 0..$#$termdefs;

    return @return;
}


# $self->debug([NCONTRIBS]);
sub debug {
    my $self = shift;
    my $ncontribs = shift || $self->{'ncontribs'} || 8;
    my @return;
    my $x;
    my $y;
    my $last = '';
    my %credit;
    my @credittop;
    my $credittext;
    my $num_terms = 0;			# number of terms
    my $num_definitions = 0;	# total number of definitions in all terms

    my $top_n = $ncontribs;	# display this many top contributors

    while (my ($term, $termdata) = each %{$self->{'db'}}) {
	$num_terms++;
	$num_definitions += @$termdata;

	$credit{$_->[0]}++ for @$termdata;
    }

    @credittop = sort { $credit{$b} <=> $credit{$a} } keys %credit;

    $top_n = @credittop if $top_n > @credittop;

    $credittext = "Top contributors: " . join ' ',
    map "$_($credit{$_})", @credittop[0.. $top_n-1 ];

    push(@return,"There are $num_definitions entries in the dictionary for $num_terms terms, added by " . scalar(keys(%credit)) . " people.");
    push(@return, $credittext);
    return @return;
}

1;

__END__
