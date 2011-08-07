use strict;
use warnings;

use diagnostics;  # For development

use Math::Expression::Evaluator;
use Try::Tiny;
use POSIX qw( strftime );


my @nh_roles = ('Arc', 'Bar', 'Cav', 'Hea', 'Kni', 'Mon', 'Pri', 'Rog', 'Ran', 'Sam', 'Tou', 'Val', 'Wiz');
my @nh_races = ('Hum', 'Elf', 'Dwa', 'Orc', 'Gno');
my @nh_aligns = ('Law', 'Neu', 'Cha');
my @nh_genders = ('Mal', 'Fem');

sub decode_conduct_part {
    my ($dat, $val, $str) = @_;
    return $str if ($dat & $val);
    return "";
}


sub read_textdata_file {
    my $fname = shift || die "no textdata file given";
    open(my $fh, $fname) || die "cannot read text data file $fname.";
    my @data = <$fh>;
    close($fh);
    foreach (@data) { $_ =~ s/\n$//; }
    return @data;
}

sub get_inner_str {
    my $str = shift;

    my $brackets = 0;

    for (my $i = 0; $i < length($str); $i++) {
	my $c = substr($str, $i, 1);
	if ($c eq "(") { $brackets++; }
	elsif ($c eq ")") {
	    $brackets--;
	    if ($brackets == 0) {
		return substr($str, 1, $i-1);
	    }
	}
    }
    return $str;
}

sub paramstr_rot13 {
    my $s = shift || "";
    $s =~ tr/a-zA-Z/n-za-mN-ZA-M/;
    return $s;
}

# return a random value from str_rnd("2,5") or str_rnd("3d6");
sub paramstr_rnd {
    my $s = shift;
    my $rndval = 0;
    if ($s =~ m/^(-?\d+[d,])?(\d+)$/) {
	my $rndval1 = $1 || undef;
	my $rndval2 = $2;
	if (defined $rndval1) {
	    if ($rndval1 =~ m/d$/) { # it's XdY
		$rndval1 =~ s/d$//;
		$rndval = diceroll($rndval1,$rndval2);
	    } else {
		$rndval1 =~ s/,$//; # it's X,Y
		$rndval = int rand($rndval2) + $rndval1;
	    }
	} else {
	    $rndval = int rand($rndval2);
	}
    }
    return $rndval;
}

# paramstr_math("3+(2*4)/2")
sub paramstr_math {
    my $expr = shift || "";

    return unless $expr =~ /^[-\d\+\*\/\(\)]+$/;
    return try { Math::Expression::Evaluator->new->parse($expr)->val };
}


# paramstr_shuffle("a|b|c")
sub paramstr_shuffle {
    my $param = shift || "";
    my @c = ( split /\|/, $param );
    my ($i, $j);
    # Knuth shuffle
    for ($i = 0; $i < @c - 1; ++$i) {
	$j = rand(@c - $i) + $i;
	($c[$i], $c[$j]) = ($c[$j], $c[$i]);
    }
    $i = join(' ', @c);
    return $i;
}

# paramstr_nplural("1|foo") -> a foo
# paramstr_nplural("2|foo") -> 2 foos
sub paramstr_nplural {
    my $s = shift || "";
    if ($s =~ m/^(\d+)\|(.+)$/) {
	my $cnt = int($1);
	my $foo = $2 || "";
	return an($foo) if ($cnt == 1);
	return makeplur($foo);
    }
    return makeplur($s);
}

# paramstr_trim(" a ") -> "a"
sub paramstr_trim {
    my $s = shift || "";
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

# paramstr_rmpipes("a|b|c") -> "a b c"
sub paramstr_rmpipes {
    my $s = shift || "";
    $s =~ s/\|/ /g;
    return $s;
}

# paramstr_replacestr("a|b|abc") -> "bbc"
sub paramstr_replacestr {
    my $str = shift || "";
    if ($str =~ m/^(.+)\|(.*)\|(.*)$/) {
	my $search = $1;
	my $replace = $2 || "";
	my $haystack = $3 || "";
	$haystack =~ s/\Q$search\E/\Q$replace\E/g;
	return $haystack;
    }
    return $str;
}

sub paramstr_lc { return lc(shift || ""); }
sub paramstr_uc { return uc(shift || ""); }
sub paramstr_lcfirst { return lcfirst(shift || ""); }
sub paramstr_ucfirst { return ucfirst(shift || ""); }
sub paramstr_strlen { return length(shift || ""); }
sub paramstr_timefmt { return strftime(shift || "", localtime); }


sub perhaps_you_meant {
    my $searched = shift;
    my @fields = @_;

    my @found = grep(/\Q$searched\E/i, @fields);

    if (scalar @found) {
	@found = @found[0..2] if ((scalar @found) > 3); 
	return ", perhaps you meant ".join(" or ", @found);
    }
    return "";
}

sub is_aggregate_func {
    my $str = shift;   # eg. "avg(hp)"

    my @aggregates = ("avg", "count", "max", "min", "sum");

    my ($a, $f) = $str =~ /^([a-z]+)\(([^)]+)\)$/;

    if ((defined $a) && (defined $f)) {
	if (grep {$_ eq $a} @aggregates) {
	    my %ret = (aggregate => $a, field => $f);
	    return %ret;
	}
    }
    return;
}

# converted from nethack's makeplural
sub makeplur {
    my $s = shift || "";
    return $s if ($s =~ m/^pair of /);

    my $excess = "";

    for (my $i = 0; $i < length($s); $i++) {
	my $c = substr($s, $i);
	if ($c =~ m/^ of / ||
	    $c =~ m/^ labeled / ||
	    $c =~ m/^ called / ||
	    $c =~ m/^ named / ||
	    $c =~ m/^ above/ ||
	    $c =~ m/^ versus / ||
	    $c =~ m/^ from / ||
	    $c =~ m/^ in / ||
	    $c =~ m/^ on / ||
	    $c =~ m/^ a la / ||
	    $c =~ m/^ with/ ||
	    $c =~ m/^ de / ||
	    $c =~ m/^ d'/ ||
	    $c =~ m/^ du /) {
	    $excess = $c;
	    $s = substr($s, 0, $i);
	    last;
	}
    }

    $s =~ s/\s+$//;

    my $len = length($s);

    return $s."'s".$excess if ($len == 1);

    if (($s =~ m/^ya$/) ||
	($s =~ m/ai$/) ||
	($s =~ m/ ya$/) ||
	($s =~ m/fish$/) ||
	($s =~ m/tuna$/) ||
	($s =~ m/deer$/) ||
	($s =~ m/yaki$/) ||
	($s =~ m/sheep$/) ||
	($s =~ m/ninja$/) ||
	($s =~ m/ronin$/) ||
	($s =~ m/shito$/) ||
	($s =~ m/shuriken$/) ||
	($s =~ m/tengu$/) ||
	($s =~ m/manes$/) ||
	($s =~ m/ki-rin$/) ||
	($s =~ m/gunyoki$/)) {
	return $s.$excess;
    }

    if ($s =~ m/man$/ ||
	$s =~ m/shaman$/ ||
	$s =~ m/human$/) {
	$s =~ s/man$/men/;
	return $s.$excess;
    }

    if ($s =~ m/tooth$/) {
	$s =~ s/tooth$/teeth/;
	return $s.$excess;
    }

    if ($s =~ m/fe$/) {
	$s =~ s/fe$/ves/;
	return $s.$excess;
    } elsif ($s =~ m/f$/) {
	if ($s =~ m/[lraeiouyAEIOUY]f$/) {
	    $s =~ s/$/ves/;
	    return $s.$excess;
	} elsif ($s =~ m/staf$/) {
	    $s =~ s/f$/ves/;
	    return $s.$excess;
	}
    }

    if ($s =~ m/foot$/) {
	$s =~ s/foot$/feet/;
	return $s.$excess;
    }

    if ($s =~ m/ium$/) {
	$s =~ s/ium$/ia/;
	return $s.$excess;
    }

    if ($s =~ m/alga$/ ||
	$s =~ m/hypha$/ ||
	$s =~ m/larva$/) {
	return $s."e".$excess;
    }

    if ($s =~ m/us$/ && !($s =~ m/lotus$/ || $s =~ m/wumpus$/)) {
	$s =~ s/us$/i/;
	return $s.$excess;
    }

    if ($s =~ m/rtex$/) {
	$s =~ s/ex$/ices/;
	return $s.$excess;
    }

    if ($s =~ m/djinni$/) {
	$s =~ s/i$//;
	return $s.$excess;
    }

    if ($s =~ m/mumak$/) {
	return $s."il".$excess;
    }

    if ($s =~ m/sis$/) {
	$s =~ s/sis$/ses/;
	return $s.$excess;
    }

    if ($s =~ m/erinys$/) {
	$s =~ s/s$/es/;
	return $s.$excess;
    }

    if ($s =~ m/[mMlL]ouse$/) {
	$s =~ s/ouse$/ice/;
    }

    if ($s =~ m/matzoh$/ || $s =~ m/matzah/) {
	$s =~ s/..$/ot/;
	return $s.$excess;
    }
    if ($s =~ m/matzo$/ || $s =~ m/matza/) {
	$s =~ s/.$/ot/;
	return $s.$excess;
    }

    if ($s =~ m/child$/) {
	$s =~ s/d$/dren/;
	return $s.$excess;
    }

    if ($s =~ m/goose$/) {
	$s = "geese";
	return $s.$excess;
    }

    if ($s =~ m/[zxs]$/ ||
	$s =~ m/[cs]h$/) {
	return $s."es".$excess;
    }

    if ($s =~ m/ato$/) {
	return $s."es".$excess;
    }

    if ($s =~ m/[^aeiouy]y$/) {
	$s =~ s/.$/ies/;
	return $s.$excess;
    }

    return $s."s".$excess;

}


# NetHack Specific stuff

sub get_pom_str {
    # this code appears to work even at end-of-year and during leap years

    my (undef, undef, $hour, undef, undef, $year, undef, $diy) = localtime;
    $year += 1900; # Perl's localtime gives years since 1900

    my $current_phase = phase_of_the_moon($diy, $year);
    my $inphase = !!($current_phase == 0 || $current_phase == 4); # 1 if full/new moon, 0 otherwise

    my $leapyear = !!(!($year % 4) && (($year % 100) || !($year % 400))); # 1 if $year is a leap year, 0 otherwise
    my ($next_diy, $next_year, $next_phase, $next_inphase) = ($diy, $year, $current_phase, $inphase);
    my $days = 0;
    my $pom;

    # this loop runs a maximum of ~12 times
    do {
	$next_diy++;
	$days++;
	if ($next_diy - $leapyear == 365) { # if we've exceeded the days in the current year
	    $next_diy = 0;
	    ++$next_year;
	}
	$next_phase = phase_of_the_moon($next_diy, $next_year);
	$next_inphase = !!($next_phase == 0 || $next_phase == 4);
    } while $inphase == $next_inphase;

    if ($current_phase == 0) { # currently a new moon
	$pom = "New moon in NetHack " . ($days == 1 ? "until midnight, " : "for the next $days days.");
    } elsif ($current_phase == 4) { # currently a full moon
	$pom = "Full moon in NetHack " . ($days == 1 ? "until midnight, " : "for the next $days days.");
    } elsif ($current_phase < 4) { # currently a waxing moon
	$pom = "Full moon in NetHack " . ($days == 1 ? "at midnight, " : "in $days days.");
    } else { # currently a waning moon
	$pom = "New moon in NetHack " . ($days == 1 ? "at midnight, " : "in $days days.");
    }

    $pom .= (24 - $hour) . " hour" . (24 - $hour == 1 ? "" : "s") . " from now." if $days == 1;

    my $prefix = `/usr/games/pom`;
    chomp($prefix);
    $pom = $prefix.'.  '.$pom;

    return $pom;
}


sub dogrepsrc {
    my $grepstr = shift;
    my $srcfiles = shift || "/opt/nethack/rodney/data/nh343/src/*.[ch] /opt/nethack/rodney/data/nh343/include/*.[ch]";

    $grepstr =~ s/["']/./g;

    my $grepline = "grep -n \"$grepstr\" $srcfiles";

    my @lines = split(/\n/, `$grepline`);

    if (scalar(@lines) > 3) {
	return "Sorry, too many (".scalar(@lines).") matches.";
    } elsif (scalar(@lines) < 1) {
	return "Sorry, no matches.";
    } else {
	my $ret;
	foreach my $a (@lines) {
	        my ($srcfile, $linenum) = $a =~ m/^([^:]+):([0-9]+):/;
		if (defined $srcfile && defined $linenum) {
		    $ret .= "  " if ($ret);
		    $ret .= "http://nethackwiki.com/wiki/Source:".basename($srcfile)."#line".$linenum;
		}
	}
	return scalar(@lines)." matches: ".$ret;
    }
}

sub an {
    my $text = shift;
    $text =~ s/^\s+//;
    if (($text =~ m/^[aeiouAEIOU]/) && !($text =~ m/^one-/) && !($text =~ m/^useful/)
	&& !($text =~ m/^unicorn/) && !($text =~ m/^uranium/) && !($text =~ m/^eucalyptus/)) {
	return "an ".$text;
    }
    return "a ".$text;
}


sub parse_logline {
    my $line = shift;

    my ($version,$points,$dnum,$dlev,$maxlvl,$hp,$maxhp,$ndeaths,$edate,$sdate,$crga,$name,$death) = $line =~
	/^(3.\d.\d+) ([\d\-]+) ([\d\-]+) ([\d\-]+) ([\d\-]+) ([\d\-]+) ([\d\-]+) (\d+) (\d+) (\d+) \d+ ([A-Z][a-z]+ [A-Z][a-z]+ [MF][a-z]+ [A-Z][a-z]+) ([^,]+),(.*)$/;

    my %ret;

    $ret{'version'} = $version;
    $ret{'points'} = $points;
    $ret{'dnum'} = $dnum;
    $ret{'dlev'} = $dlev;
    $ret{'maxlvl'} = $maxlvl;
    $ret{'hp'} = $hp;
    $ret{'maxhp'} = $maxhp;
    $ret{'ndeaths'} = $ndeaths;
    $ret{'edate'} = $edate;
    $ret{'sdate'} = $sdate;
    $ret{'crga'} = $crga;
    $ret{'name'} = $name;
    $ret{'death'} = $death;

    return %ret;
}


# Like parse_logline() but operates on a line from the extended logfile
sub parse_xlogline {
    my $line = shift;
    my $compat = shift || undef;

    my %ret;

    my @dat = ( split /:/, $line );

    my $a;

    foreach $a (@dat) {
        my @tmpd = ( split /=/, $a );
        $ret{$tmpd[0]} = $tmpd[1];
    }

    if (!$compat) {
# backwards compatible
	$ret{'crga'} = $ret{'role'}.' '.$ret{'race'}.' '.$ret{'gender'}.' '.$ret{'align'};
	$ret{'dnum'} = $ret{'deathdnum'};
	$ret{'dlev'} = $ret{'deathlev'};
	$ret{'ndeaths'} = $ret{'deaths'};
	$ret{'edate'} = $ret{'deathdate'};
	$ret{'sdate'} = $ret{'birthdate'};
    }

    return %ret;
}

sub xlog2record {
    my $line = shift;

    my %dat = parse_xlogline($line);

    return "$dat{'version'} $dat{'points'} $dat{'deathdnum'} $dat{'deathlev'} $dat{'maxlvl'} $dat{'hp'} $dat{'maxhp'} $dat{'deaths'} $dat{'deathdate'} $dat{'birthdate'} $dat{'uid'} $dat{'role'} $dat{'race'} $dat{'gender'} $dat{'align'} $dat{'name'},$dat{'death'}";
}


# cannot handle 3.2.x or lower.
sub demunge_recordline {
    my $logline = shift;
    my $verbosity = shift || 0;

    my $line;

    my @dungeons = ("DoD", "Gehennom", "Mines", "Quest", "Sokoban", "Ludios", "Vlad's", "Plane");
    my @planes = ("dummy", "Earth", "Air", "Fire", "Water", "Astral");

    my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time());
    my $cdate = sprintf("20%02d%02d%02d", $year%100, $mon+1, $mday);

    my %dat = parse_logline($logline);

    $line = "$dat{'name'} ($dat{'crga'})";

    $line = $line . ", $dat{'death'}, $dat{'points'} points";

    if ($verbosity > 2) {
	$line = $line . ", HP:$dat{'hp'}";
	$line = $line . "($dat{'maxhp'})" if ($dat{'maxhp'} != $dat{'hp'});
    }

    if ($verbosity > 1) {
	# dungeon levels reached
	if ($dat{'death'} =~ /ascended/) {
	    $line = $line . ", max depth: $dat{'maxlvl'}";
	} else {
	    my $tmpn;
	    if ($dat{'dlev'} < 0) {
		$tmpn =  $planes[-$dat{'dlev'}] . " " . $dungeons[$dat{'dnum'}];
	    } else {
		$tmpn = "lvl:" . $dat{'dlev'} . " of " . $dungeons[$dat{'dnum'}];
	    }
	    if ($dat{'maxlvl'} != $dat{'dlev'}) {
		$tmpn = $tmpn . ", max depth: $dat{'maxlvl'}";
	    }
	    $line = $line . ", " . $tmpn;
	}
    }

    if ($verbosity > 3) {
	# number of deaths
	if (($dat{'ndeaths'} > 1) || (($dat{'ndeaths'} > 0) && ($dat{'death'} =~ /ascended/))) {
	    my $tmpn;
	    $tmpn = "once" if ($dat{'ndeaths'} == 1);
	    $tmpn = "twice" if ($dat{'ndeaths'} == 2);
	    $tmpn = "thrice" if ($dat{'ndeaths'} == 3);
	    $tmpn = "$dat{'ndeaths'} times" if ($dat{'ndeaths'} >= 4);
	    $line = $line . ", died $tmpn";
	}
    }

    if ($verbosity > 4) {
	# playing dates
	if (!($dat{'edate'} == $cdate) || !($dat{'sdate'} == $dat{'edate'})) {
	    if ($dat{'edate'} == $cdate) {
		$line = $line . ", started on $dat{'sdate'}";
	    } else {
		$line = $line . ", played on $dat{'sdate'}-$dat{'edate'}";
	    }
	}
    }

    if ($verbosity > 5) {
	$line = $line . ", on NH v$dat{'version'}";
    }

    return $line;
}


# Other generic stuff


sub fixstring {
    my ($str, %dat) = @_;
    my $firstchar = substr($dat{'name'}, 0, 1);
    $str =~ s/%u/$dat{'name'}/g;
    $str =~ s/%U/$firstchar/g;
    $str =~ s/%t/$dat{'starttime'}/g;
    return $str;
}


sub max { return ($_[0] < $_[1] ? $_[1] : $_[0]); }


sub time_diff {
    my ($seconds, $short) = @_;
    my $ret;

    $short = 0 unless defined $short;

    return $short ? '0s' : '0secs' if $seconds == 0;

    my $days = int($seconds / 86400);
    $seconds %= 86400;

    my $hours = int($seconds / 3600);
    $seconds %= 3600;

    my $minutes = int($seconds / 60);
    $seconds %= 60;

    $ret  = $days    . ($short ? 'd' : 'day'  . ($days    == 1 ? '' : 's')) . ' ' if $days;
    $ret .= $hours   . ($short ? 'h' : 'hour' . ($hours   == 1 ? '' : 's')) . ' ' if $hours;
    $ret .= $minutes . ($short ? 'm' : 'min'  . ($minutes == 1 ? '' : 's')) . ' ' if $minutes;
    $ret .= $seconds . ($short ? 's' : 'sec'  . ($seconds == 1 ? '' : 's')) . ' ' if ($seconds && !$ret);

    $ret =~ s/ $//; # remove the trailing space
    return $ret;
}


# $seconds = conv_hms("1h2m3s");
sub conv_hms {
    my $str = shift || "";

    my $secs = 0;
    my $mins = 0;
    my $hours = 0;
    my $days = 0;

    if ($str =~ m/^([0-9]+)d/) {
	$days = scalar($1);
	$str =~ s/^([0-9]+)d//;
    }

    if ($str =~ m/^([0-9]+)h/) {
	$hours = scalar($1);
	$str =~ s/^([0-9]+)h//;
    }

    if ($str =~ m/^([0-9]+)m/) {
	$mins = scalar($1);
	$str =~ s/^([0-9]+)m//;
    }

    if ($str =~ m/^([0-9]+)s/) {
	$secs = scalar($1);
	$str =~ s/^([0-9]+)s//;
    } elsif ($str =~ m/^([0-9]+)$/) {
	$secs = scalar($1);
    }

    return $secs + (60 * $mins) + (60 * 60 * $hours) + (24 * 60 * 60 * $days);
}



# @lines = splitline($longline, $length);
sub splitline {
    my $line = shift;
    my $chop;
    my $length = shift || 300;
    my @ret;

    while (length($line) > $length) {
	# Here we just need the effects of the capturing parentheses.
	# We break at the last space possible. If no space, then at length characters.
	# I could've put ($chop, $line) in each brace pair, but better to have it just once.

	if ($line =~ /^(.{1,$length}) +(.*)$/o) { }
	elsif ($line =~ /^(.{$length})(.*)$/o) { }

	($chop, $line) = ($1, $2);

	# remove any trailing or leading whitespace
	$chop =~ s/^ +//;
	$line =~ s/^ +//;
	$chop =~ s/ +$//;
	$line =~ s/ +$//;

	# visual indicator of the choppage
	$chop = $chop . '...';
	$line = '...' . $line;

	push @ret, $chop;
    }

    push @ret, $line unless $line eq '';
    return @ret;
}


# phase_of_the_moon(day of the year 0..364 (0..365 if leap year), year in YYYY format)
sub phase_of_the_moon {
    # stol^H^H^H^Hconverted directly from NetHack's source code
    my ($diy, $year) = @_;

    my $goldn = ($year % 19) + 1;
    my $epact = (11 * $goldn + 18) % 30;
    $epact++ if ($epact == 25 && $goldn > 11) || $epact == 24;

    return ((((($diy + $epact) * 6) + 11) % 177) / 22) & 7;
}


# diceroll($numdice, $numsides)
sub diceroll {
	my ($n,$d) = @_;
	return 0 if $n*$d==0 || $n<0 || $d<0;
	return $n if $d==1;
	my $t = 0;
	for(my $i=0;$i<$n;$i++){ $t += int rand($d) + 1;}
	return $t
}


# takes learn_edit s/// regex, excluding the 's' prefix
# returns (firstpart, secondpart, options) on success
# returns () and sets $@ to an error message on failure.
# necessary because a regex isn't very good for parsing a regex...
sub grok_learn_edit_regex {
    # It will be a real pain in the ass to write a new state machine
    # for handling Perl's regex parser, so I'll just
    # do this: find the closing character.  If qr[] won't work on it,
    # try finding the closing character again.
    my %closemap = ( '[' => ']', '{' => '}', '<' => '>', '(' => ')' );
    my $str = shift;
    $str =~ s/\s+$//;
    my $openchar = substr($str, 0, 1, ''); # remove the regex-start character.
    my $closechar = exists $closemap{$openchar} ? $closemap{$openchar} : $openchar;
    # note that, if $openchar eq $closechar, the form is s<open>search<open>replace<open>
    # while if $openchar ne $closechar, the form is s<open1>search<close1><open2>replace<close2>
    # with optionally different characters for open1 and open2.

    my ($search, $replace, $option);

    $str .= '?';  # so split will always include an 'options' portion.

    my @list = split /\Q$closechar/, $str;

    $search = shift @list;
    until ( eval { qr/$search/ } ) {
	# we still don't have the first half of the s/// expression yet.
	# if we don't have at least 2 items left in the list,
        # then we don't have enough stuff to even form a complete
	# expression (we need 1 item to append this round, plus 1 more to
	# possibly serve as the replacement part of the expression.
	if ( @list < ( $openchar eq $closechar) ? 3 : 2 ) {
	    $@ = "I can't grok that matching regex!";
	    return ();
	}

	$search .= $closechar . shift @list;
    }
    # at this point, $search should correctly contain the user's intended
    # substitution match regex, and join(@list, $closechar) should be
    # the rest of it (replacement text + options)

    if ($openchar ne $closechar) {
	# this is a little trickier. We need to get the new open/close character.
	my $tmp = join $closechar, @list;

	# get the new open/close character set
	$openchar = substr($tmp, 0, 1, '');
	$closechar = exists $closemap{$openchar} ? $closemap{$openchar} : $openchar;
	@list = split /\Q$closechar/, $tmp;

	# now, at this point, the same logic will work for the regular case.
    }

    $option = pop @list;
    $replace = join $closechar, @list;

    chop $option;  # remove the '?' we appended earlier.
    if ($option =~ /([^gi])/) {
	$@ = "Sorry, option '$1' isn't allowed.";
	return ();
    }

    return ($search, $replace, $option);
}


# extract_query_and_target(prefix, text, nick, channel) shall return (term, definition-to, errors-to, noticeflag)
# (7/19/2004 3:10PM) by Stevie-O
sub extract_query_and_target {
	my ($prefix, $text, $nick, $chan) = @_;
	# the default person to send things to
	my $defto = ($prefix =~ />$/ ? $chan : $nick);
	my $errto = $defto;
	my $donotice = $prefix =~ /<$/;

	# foo > nickchan
	# foo >> nickchan

	if ($text =~ /^\s*(.+)\s*>>?\s*(\S+)\s*$/) {
		# directed to a particular person
		($text, $defto) = ($1, lc $2);
	}

	# don't send notices to channels
	$donotice &&= $defto !~ /^#/;

	return ($text, $defto, $errto, $donotice);
}


# find_files("/dir/to/look/in/", "filemask");
sub find_files {
    my $path = shift || "./";
    my $fmask = shift || ".*";
    my @return;
    my @files;

    opendir DIR, $path or return @return;
    @files = grep !/^\./, readdir(DIR);

    eval { @return = grep /$fmask/i, @files; };

    return @return;
}


# takes a string of the form "3*foo|2*bar|baz" without quotes
# its runtime is dependent on the number of |, not the magnitude of *
sub choice {
    my $choicestr = shift;
    my $return;
    my $sum = 0;
    my $i;

    my @choices = split /\|/, ' '.$choicestr.' ';
    my @counts;

    $choices[0] = substr($choices[0], 1);
    $choices[@choices-1] = substr($choices[@choices-1], 0, -1);

    for ($i = 0; $i < @choices; ++$i) {
	if ($choices[$i] =~ /^(\d+)\*(.*)$/) {
	    $choices[$i] = $2;
	    push @counts, $1;
	    $sum += $1;
	} else {
	    push @counts, 1;
	    $sum += 1;
	}
    }

    $sum = rand $sum;

    for ($i = 0; $i < @choices; ++$i) {
	$sum -= $counts[$i];
	return $choices[$i] if $sum < 0;
    }

    return $choices[0];
}


# Random role-race-gender-align combo
sub random_nh_char {
    my @races = ('Hum');   # all roles can be human...
    my @genders = ('Fem'); # ...and female
    my @aligns;
    my ($role, $race, $gender, $align);

    $role = paramstr_trim(shift) || $nh_roles[rand @nh_roles];

    $role = substr($role,0,3) if (length($role) > 3);

    $role = ucfirst(lc($role));

    push(@genders, 'Mal') unless ($role eq 'Val');

    $gender = $genders[rand @genders];

    push(@races, 'Dwa') if ($role eq 'Arc' || $role eq 'Cav' || $role eq 'Val');
    push(@races, 'Elf') if ($role eq 'Pri' || $role eq 'Ran' || $role eq 'Wiz');
    push(@races, 'Gno') if ($role eq 'Arc' || $role eq 'Cav' || $role eq 'Hea' || $role eq 'Ran' || $role eq 'Wiz');
    push(@races, 'Orc') if ($role eq 'Bar' || $role eq 'Ran' || $role eq 'Rog' || $role eq 'Wiz');

    $race = $races[rand @races];

    # most races are of a set alignment...
    push(@aligns, 'Law') if ($race eq 'Dwa');
    push(@aligns, 'Neu') if ($race eq 'Gno');
    push(@aligns, 'Cha') if ($race eq 'Elf' || $race eq 'Orc');

    # ...but humans are tricksy
    if ($race eq 'Hum')
    {
        push(@aligns, 'Law') if ($role eq 'Arc'|| $role eq 'Cav'|| $role eq 'Kni'|| $role eq 'Mon'|| $role eq 'Pri'||
                                $role eq 'Sam'|| $role eq 'Val');
        push(@aligns, 'Neu') if ($role eq 'Arc'|| $role eq 'Bar'|| $role eq 'Cav'|| $role eq 'Hea'|| $role eq 'Mon'||
                                $role eq 'Pri'|| $role eq 'Ran'|| $role eq 'Tou'|| $role eq 'Val'|| $role eq 'Wiz');
        push(@aligns, 'Cha') if ($role eq 'Bar'|| $role eq 'Mon'|| $role eq 'Pri'|| $role eq 'Rog'|| $role eq 'Ran'||
                                $role eq 'Wiz');
    }

    $align = $aligns[rand @aligns];

    return $role.' '.$race.' '.$gender.' '.$align;
}


1;

__END__
