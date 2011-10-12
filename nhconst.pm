package nhconst;

our @roles = ('Arc', 'Bar', 'Cav', 'Hea', 'Kni', 'Mon', 'Pri', 'Rog', 'Ran', 'Sam', 'Tou', 'Val', 'Wiz');
our @races = ('Hum', 'Elf', 'Dwa', 'Orc', 'Gno');
our @aligns = ('Law', 'Neu', 'Cha');
our @genders = ('Mal', 'Fem');
our @BUC = ('blessed', 'uncursed', 'cursed');

our @roles_long = ('archeologist', 'barbarian', 'caveman', 'healer', 'knight', 'monk', 'priest', 'rogue', 'ranger', 'samurai', 'tourist', 'valkyrie', 'wizard');
our @races_long = ('human', 'elf', 'dwarf', 'orc', 'gnome');
our @aligns_long = ('lawful', 'neutral', 'chaotic');
our @genders_long = ('male', 'female');

our %dnums = (
    0 => "Dungeons",
    1 => "Gehennom",
    2 => "Mines",
    3 => "Quest",
    4 => "Soko",
    5 => "Ludios",
    6 => "Vlad",
    7 => "Planes",
    -5 => "Astral",
    -4 => "Water",
    -3 => "Fire",
    -2 => "Air",
    -1 => "Earth");

our %dnums_short = (
    0 => "Dng",
    1 => "Geh",
    2 => "Min",
    3 => "Que",
    4 => "Sok",
    5 => "Lud",
    6 => "Vld",
    7 => "Planes",
    -5 => "Astral",
    -4 => "Water",
    -3 => "Fire",
    -2 => "Air",
    -1 => "Earth");

our %gods = (
    'arc' => ["Quetzalcoatl", "Camaxtli", "Huhetotl"],
    'bar' => ["Mitra", "Crom", "Set"],
    'cav' => ["Anu", "_Ishtar", "Anshar"],
    'hea' => ["_Athena", "Hermes", "Poseidon"],
    'kni' => ["Lugh", "_Brigit", "Manannan Mac Lir"],
    'mon' => ["Shan Lai Ching", "Chih Sung-tzu", "Huan Ti"],
    'pri' => [undef, undef, undef],
    'rog' => ["Issek", "Mog", "Kos"],
    'ran' => ["Mercury", "_Venus", "Mars"],
    'sam' => ["_Amaterasu Omikami", "Raijin", "Susanowo"],
    'tou' => ["Blind Io", "_The Lady", "Offler"],
    'val' => ["Tyr", "Odin", "Loki"],
    'wiz' => ["Ptah", "Thoth", "Anhur"]
    );
