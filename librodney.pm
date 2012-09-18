use strict;
use warnings;

use diagnostics;  # For development

use Math::Expression::Evaluator;
use Try::Tiny;
use POSIX qw( strftime );
use Time::Local;

use nhconst;

sub debugprint {
    my $ts = localtime(time());
    print "[$ts] " . join(" ", @_) . "\n";
}


# decode_xlog_datastr("conduct", "0x102")
sub decode_xlog_datastr {
    my ($a, $b) = @_;
    my $ret = "";
    if ($a =~ m/realtime/) {
	$ret = time_diff($b, 1);
    } elsif ($a =~ m/nconducts/) {
	$ret = $b;
    } elsif ($a =~ m/conduct/) {
	$ret  = decode_conduct_part($b, 0x0001, "Foo");
	$ret .= decode_conduct_part($b, 0x0002, "Vgn");
	$ret .= decode_conduct_part($b, 0x0004, "Vgt");
	$ret .= decode_conduct_part($b, 0x0008, "Ath");
	$ret .= decode_conduct_part($b, 0x0010, "Wea");
	$ret .= decode_conduct_part($b, 0x0020, "Pac");
	$ret .= decode_conduct_part($b, 0x0040, "Ill");
	$ret .= decode_conduct_part($b, 0x0080, "Ppl");
	$ret .= decode_conduct_part($b, 0x0100, "Psf");
	$ret .= decode_conduct_part($b, 0x0200, "Wis");
	$ret .= decode_conduct_part($b, 0x0400, "Art");
	$ret .= decode_conduct_part($b, 0x0800, "Gen");
    } elsif ($a =~ m/^achieve$/) {
	$ret  = decode_conduct_part($b, 0x0001, "Bel");
	$ret .= decode_conduct_part($b, 0x0002, "Geh");
	$ret .= decode_conduct_part($b, 0x0004, "Can");
	$ret .= decode_conduct_part($b, 0x0008, "Boo");
	$ret .= decode_conduct_part($b, 0x0010, "Inv");
	$ret .= decode_conduct_part($b, 0x0020, "Amu");
	$ret .= decode_conduct_part($b, 0x0040, "Pla");
	$ret .= decode_conduct_part($b, 0x0080, "Ast");
	$ret .= decode_conduct_part($b, 0x0100, "Asc");
	$ret .= decode_conduct_part($b, 0x0200, "Luc");
	$ret .= decode_conduct_part($b, 0x0400, "Sok");
	$ret .= decode_conduct_part($b, 0x0800, "Med");
    } elsif ($a =~ m/starttime/ || $a =~ m/endtime/) {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($b);
	$ret = sprintf("%04d%02d%02d %02d:%02d:%02d", ($year+1900), ($mon+1), $mday, $hour,$min,$sec);
    } elsif (($a =~ m/deathdnum/) || ($a =~ m/deathlev/)) {
	$ret = $b;
	$ret = $nhconst::dnums{$b} if (($b < 0) || ($a =~ m/deathdnum/));
    } else {
	$ret = $b;
    }
    return $ret;
}

sub decode_conduct_part {
    my ($dat, $val, $str) = @_;
    return $str if ($dat & $val);
    return "";
}


sub read_textdata_file {
    my $fname = shift || return ("no textdata file given");
    open(my $fh, $fname) || return ("cannot read text data file $fname.");
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

sub paramstr_possessive {
    my $s = shift || "";
    return $s."s" if ($s =~ m/^it$/i);
    return $s."'" if ($s =~ m/s$/i);
    return $s."'s";
}

# return a random god, or one for the role we want paramstr_rndgod("wiz")
sub paramstr_rndgod {
    my $role = shift || undef;
    my $god;
    my $idx = 0;
    my @roles = keys(%nhconst::gods);
    if (grep { lc($_) eq $role } @nhconst::aligns ) {
	my @tmpgods;
	$idx = 1 if ($role eq lc($nhconst::aligns[1]));
	$idx = 2 if ($role eq lc($nhconst::aligns[2]));
	foreach (@roles) {
	    push(@tmpgods, $nhconst::gods{$_}[$idx]) if ($_ ne "pri");
	}
	$god = $tmpgods[rand(@tmpgods)];
    } else {
	$idx = int(rand(3));
	$role = lc(substr($role, 0, 3)) if ($role);
	while (!$role || $role eq "pri") {
	    $role = $roles[rand(@roles)];
	}
	$god = $nhconst::gods{$role}[$idx];
    }
    $god =~ s/^_//g;

    return $god;
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
    $expr = paramstr_unescape($expr);
    my $m = Math::Expression::Evaluator->new();
    $m->set_function('abs', sub { abs($_[0]) });
    $m->set_function('rn2', sub { int(rand($_[0])) });
    $m->set_function('rnd', sub { int(rand($_[0]) + 1) });
    my $ret = try { $m->parse($expr)->val };
    return paramstr_escape($ret);
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

sub paramstr_ordin {
    my $s = shift || 0;
    if ($s =~ m/^(\d+)$/) {
	my $dd = (int($1) % 10);
	return $s . ((($dd == 0) || ($dd > 3) || ((int($s) % 100) / 10 == 1)) ? "th" :
            ($dd == 1) ? "st" : ($dd == 2) ? "nd" : "rd");
    }
    return $s."th";
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

# paramstr_escape("a|b|c") -> "a\x01b\x01c"
sub paramstr_escape {
    my $s = shift || "";
    $s =~ s/\|/\x01/g;
    return $s;
}

# paramstr_unescape("a\x01b\x01c") -> "a|b|c", usually used for $ARGS
sub paramstr_unescape {
    my $s = shift || "";
    $s =~ s/\x01/|/g;
    return $s;
}

# positive integer
sub paramstr_isint {
    my $s = shift || "";
    return "1" if ($s =~ m/^[0-9]+$/);
    return "0";
}
# positive or negative integer
sub paramstr_isnum {
    my $s = shift || "";
    return "1" if ($s =~ m/^[+-]?[0-9]+$/);
    return "0";
}
# alphabetic letter (a-zA-Z)
sub paramstr_isalpha {
    my $s = shift || "";
    return "1" if ($s =~ m/^[a-zA-Z]+$/);
    return "0";
}
# alpha or numeric letter (a-zA-Z0-9)
sub paramstr_isalphanum {
    my $s = shift || "";
    return "1" if ($s =~ m/^[a-zA-Z0-9]+$/);
    return "0";
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

# paramstr_substr("foo|0|1") => "f"
# paramstr_substr("foo|1") => "oo"
sub paramstr_substr {
    my $s = shift || "";
    if ($s =~ m/^(.*)\|(.*)\|(.*)$/) {
	my $str = $1;
	my $offset = $2 || 0;
	my $len = $3 || 0;
	return substr($str, $offset, $len);
    } elsif ($s =~ m/^(.*)\|(.*)$/) {
	my $str = $1;
	my $offset = $2 || 0;
	return substr($str, $offset);
    }
    return "";
}

# paramstr_index("foobar|bar") => "3"
sub paramstr_index {
    my $s = shift || "";
    if ($s =~ m/^(.*)\|(.*)$/) {
	my $str = $1;
	my $str2 = $2 || "";
	return index($str, $str2);
    }
    return "-1";
}

# paramstr_rindex("foobar|bar")
sub paramstr_rindex {
    my $s = shift || "";
    if ($s =~ m/^(.*)\|(.*)$/) {
	my $str = $1;
	my $str2 = $2 || "";
	return rindex($str, $str2);
    }
    return "-1";
}

# paramstr_rebase("123|16") changes decimal number to binary, octal or hexadecimal
sub paramstr_rebase {
    my $s = shift || "";
    my $base = 10;
    my $num = 0;
    if ($s =~ m/^(.*)\|(.*)$/) {
	$num = $1;
	$base = $2;
	if ($base eq "b") { $base = 2; }
	elsif ($base eq "o") { $base = 8; }
	elsif ($base eq "x") { $base = 16; }
	else { $base = 10; }
    } else {
	$num = $s;
    }
    return "0" if (!paramstr_isint($base) || !paramstr_isint($num));

    $base = int $base;
    $num = int $num;

    if ($base == 2) {
	return sprintf("%b", $num);
    } elsif ($base == 8) {
	return sprintf("%o", $num);
    } elsif ($base == 16) {
	return sprintf("%x", $num);
    } else {
	return $num;
    }

    return "0";
}

sub paramstr_reverse { return reverse(shift || ""); }

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

    my %aggr_renames = (
	average => "avg",
	av => "avg"
	);

    my ($a, $f) = $str =~ /^([a-z]+)\(([^)]+)\)$/;

    if ((defined $a) && (defined $f)) {
	$a = $aggr_renames{$a} if ( grep { $_ eq $a } keys(%aggr_renames) );
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
	    $s =~ s/f$/ves/;
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
	return $s.$excess;
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

    my $pathbase = "/opt/nethack/rodney/data/nh343/";

    if ($grepstr =~ m/^file=((src\/|include\/)?([a-zA-Z_*]+(\.[ch*])?))\s(.+)$/) {
	my ($fullfn, $pathfrag, $fnonly, $fileext, $searchstr) = ($1, $2, $3, $4, $5);

	$srcfiles = "";

	if (!$pathfrag) {
	    $srcfiles = $pathbase."src/".$fullfn.(!$fileext ? ".c" : "");
	    $srcfiles .= " ".$pathbase."include/".$fullfn.(!$fileext ? ".h" : "");
	} else {
	    $srcfiles = $pathbase.$fullfn.(!$fileext ? ".[ch]" : "");;
	}
	$grepstr = $searchstr;
    }

    my $tmpstr = $grepstr;
    $tmpstr =~ s/[^a-zA-Z0-9]//g;

    $grepstr =~ s/["')(\[\]]/./g;

    $grepstr =~ s/\\/./g;

    return "Need something sensible to look for." if ($tmpstr eq "");

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
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($dat{'starttime'} || time());
    my $ttyrecfile = sprintf("%04d-%02d-%02d.%02d:%02d:%02d", ($year+1900), ($mon+1), $mday, $hour,$min,$sec);
    $str =~ s/%u/$dat{'name'}/g if ($dat{'name'});
    $str =~ s/%U/$firstchar/g if ($firstchar);
    $str =~ s/%t/$dat{'starttime'}/g if ($dat{'starttime'});
    $str =~ s/%T/$ttyrecfile/g if ($ttyrecfile);
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

# cnv_str_to_bitmask("FooVgnVgtWeaPsf", \%conduct_names);
sub cnv_str_to_bitmask {
    my $str = lc(shift);
    my $hashref = shift;
    my $mask = 0x0000;
    my $err;

    my @hashkeys = sort {length($b) <=> length($a)} keys(%{$hashref});

    return $mask if (!@hashkeys);

    do {
	$err = 1;
	foreach my $tmp (@hashkeys) {
	    if ($str =~ m/^\Q$tmp\E/) {
		$mask |= $hashref->{$tmp};
		$str =~ s/^\Q$tmp\E//;
		$err = 0;
		last;
	    }
	}
    } while (!$err && ($str ne ""));
    return -1 if ($err);
    return $mask;
}


# %tmpdate = str_to_yyyymmdd("2011.11.04")
sub str_to_yyyymmdd {
    my $s = shift || "";
    my $err;
    my ($tmpy, $tmpm, $tmpd);
    if ($s eq "today" || $s eq "now") {
	($tmpy, $tmpm, $tmpd) = (localtime( time() ) )[ 5, 4, 3 ];
	$s = sprintf("%.04d%.02d%.02d", ($tmpy+1900), ($tmpm+1), $tmpd);
    } elsif ($s eq "yesterday") {
	($tmpy, $tmpm, $tmpd) = (localtime( time()-(24*60*60) ) )[ 5, 4, 3 ];
	$s = sprintf("%.04d%.02d%.02d", ($tmpy+1900), ($tmpm+1), $tmpd);
    } elsif ($s =~ m/^(now|today)?-(\d+)days?$/) {
	($tmpy, $tmpm, $tmpd) = (localtime( time()-($2 * 24*60*60) ) )[ 5, 4, 3 ];
	$s = sprintf("%.04d%.02d%.02d", ($tmpy+1900), ($tmpm+1), $tmpd);
    } elsif ($s =~ m/(20[0-1][0-9])([01][0-9])([0123][0-9])/) {
	# no need to change
    } elsif ($s =~ m/(20[0-1][0-9]).([01][0-9]).([0123][0-9])/) {
	$s = $1.$2.$3;
    } elsif ($s =~ m/([0-9]+).([0-9]+).([0-9]+)/) {
	my $d1 = $1;
	my $d2 = $2;
	my $d3 = $3;
	my $year = -1;
	my $mon = -1;
	my $day = -1;
	if ($d1 > 1900) { $year = $d1; $d1 = -1; }
	if ($d3 > 1900) { $year = $d3; $d3 = -1; }

	if ($d1 > 12) { $day = $d2; $d2 = -1; $mon = $d1; $d1 = -1; }
	if ($d3 > 12) { $day = $d3; $d3 = -1; $mon = $d2; $d2 = -1; }
	if ($d2 > 12) {
	    $day = $d2; $d2 = -1;
	    if ($d1 > 0) {
		$mon = $d1; $d1 = -1;
	    } elsif ($d3 > 0) {
		$mon = $d3; $d3 = -1;
	    }
	}

	if ($year == -1 || $mon == -1 || $day == -1 ||
	    $d1 != -1 || $d2 != -1 || $d3 != -1) {
	    $err = "ambiguous date '".$s."'";
	} else {
	    $s = $year.$mon.$day;
	}
    } else {
	$err = "unknown date '".$s."'";
    }
    return ("date" => $s, "error" => $err) if ($err);
    return ("date" => $s);
}

sub dhm_str_to_timestamp {
    my $s = lc(shift);
    my $years = 0;
    my $days = 0;
    my $hours = 0;
    my $mins = 0;
    my $secs = 0;
    $s =~ s/^(now|today)?-// if ($s =~ m/^(now|today)?-/);

    if ($s =~ m/^(\d+)(y|yrs?|years?)/) {
	$years = $1;
	$s =~ s/^(\d+)(y|yrs?|years?)//;
    }
    if ($s =~ m/^(\d+)d(ays?)/) {
	$days = $1;
	$s =~ s/^(\d+)d(ays?)//;
    }
    if ($s =~ m/^(\d+)(h|hrs?|hours?)/) {
	$hours = $1;
	$s =~ s/^(\d+)(h|hrs?|hours?)//;
    }
    if ($s =~ m/^(\d+)(m|mins?|minutes?)/) {
	$mins = $1;
	$s =~ s/^(\d+)(m|mins?|minutes?)//;
    }
    if ($s =~ m/^(\d+)(s|secs?|seconds?)/) {
	$secs = $1;
	$s =~ s/^(\d+)(s|secs?|seconds?)//;
    }
    if ($s =~ m/^$/) {
	return time() - ($years * 365*24*60*60) - ($days * 24*60*60) - ($hours * 60*60) - ($mins * 60) - $secs;
    } else {
	return -1;
    }
}

sub str_to_timestamp {
    my $s = lc(shift);
    my $tmpstamp;
    my $err;
    if ($s eq "today" || $s eq "now") {
	$s = time();
    } elsif ($s eq "yesterday") {
	$s = time() - (24*60*60);
    } elsif ($s =~ m/(20[0-1][0-9])[^0-9]?([01][0-9])[^0-9]?([0123][0-9])/) {
	my $year = $1;
	my $mon = $2;
	my $day = $3;
	$s = timelocal(0, 0, 0, $day, $mon, $year);
    } elsif ($s =~ m/^[0-9]+$/) {
	# assume it's unixtime.
    } elsif (($tmpstamp = dhm_str_to_timestamp($s)) > 0) {
	$s = $tmpstamp;
    } else {
	$err = "unknown timestamp '".$s."'";
    }
    return ("timestamp" => $s, "error" => $err) if ($err);
    return ("timestamp" => $s);
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

sub rng_choice {
    my $param = shift || "";
    my $explain = shift || 0;
    my @arg;
    my $a;
    my $retval;
    return choice($param) if ($param =~ m/\|/);

    @arg = split(/ /, $param);
    if ($arg[0] =~ /\@roles?/i) { $retval = $nhconst::roles[rand @nhconst::roles]; }
    elsif ($arg[0] =~ /\@races?/i) { $retval = $nhconst::races[rand @nhconst::races]; }
    elsif ($arg[0] =~ /\@genders?/i || $arg[0] =~ /\@sex(es)?/i) { $retval = $nhconst::genders[rand @nhconst::genders]; }
    elsif ($arg[0] =~ /\@char/i) { $retval = random_nh_char(); }
    elsif ($arg[0] =~ /\@coin/i || $arg[0] =~ /\@zorkmid/i) { @arg = ('heads','tails');	}
    elsif ($arg[0] =~ /\@align(ment)?s?/i) { $retval = $nhconst::aligns[rand @nhconst::aligns]; }
    else {
	foreach my $role (@nhconst::roles) {
	    $retval = random_nh_char($role) if $arg[0] =~ /^\@$role$/i;
	}
    }

    if ($retval) {
	return $retval if (!$explain);
	return 'The RNG says: '.$retval;
    }
    elsif ($arg[0] =~ m/^(\d*)d(\d+)$/i) {
	my ($num, $sides) = (max($1, 1), max(int $2, 1));
	if ($num <= 1000 && $sides <= 1000) {
	    my $result = diceroll($num, $sides);
	    my $dice = ($num == 1) ? 'die' : 'dice';
	    return $result if (!$explain);
	    return "The RNG rolls the $dice and gets $result.";
	} else {
	    return "42" if (!$explain);
	    return "Result: 42.";
	}
    }
    elsif ($#arg > 0) {
	$retval = $arg[rand(@arg)];
	return $retval if (!$explain);
	return 'The RNG says: '.$retval;
    }
}


# Random role-race-gender-align combo
sub random_nh_char {
    my @races = ('Hum');   # all roles can be human...
    my @genders = ('Fem'); # ...and female
    my @aligns;
    my ($role, $race, $gender, $align);

    $role = paramstr_trim(shift) || $nhconst::roles[rand @nhconst::roles];

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
