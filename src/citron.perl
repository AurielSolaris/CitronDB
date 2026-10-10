package citron;

use Fcntl qw(:flock);
use JSON::PP;

require "./src/filesystem.perl";
require "./src/config.perl";

my $VERSION = 2;
my $MAGIC = "CITRON";
my $HEADER_SIZE = length($MAGIC) + 8;

my $json = JSON::PP->new->utf8->canonical->allow_nonref;

# --- encoding -------------------------------------------------------------

# Turns raw input into a JSON value: valid JSON is parsed as-is,
# anything else is stored as a plain string.
sub parse_value {
    my ($input) = @_;

    my $value = eval { $json->decode($input) };
    return $value unless $@;

    my $string = $input;
    utf8::decode($string);
    return $string;
}

sub encode_value {
    my ($value) = @_;
    return $json->encode($value);
}

sub decode_value {
    my ($text) = @_;
    return $json->decode($text);
}

# Human-readable form: strings as-is, everything else as JSON.
sub to_text {
    my ($value) = @_;

    return "null" if !defined $value;

    if (!ref $value) {
        my $text = "$value";
        utf8::encode($text) if utf8::is_utf8($text);
        return $text;
    }

    return encode_value($value);
}

sub to_bytes {
    my ($string) = @_;
    utf8::encode($string) if utf8::is_utf8($string);
    return $string;
}

# --- file format ----------------------------------------------------------

sub serialize {
    my ($arr) = @_;

    my $binary = $MAGIC;
    $binary .= pack("N", $VERSION);
    $binary .= pack("N", scalar keys %$arr);

    foreach my $key (sort keys %$arr) {
        my $value = $arr->{$key};

        $binary .= pack("N", length($key)) . $key;
        $binary .= pack("N", length($value)) . $value;
    }

    return $binary;
}

sub deserialize {
    my ($binary) = @_;

    my %arr = ();
    my $total = length($binary);

    return \%arr if $total == 0;

    die "Not a CitronDB file (bad header)\n"
        if $total < $HEADER_SIZE || substr($binary, 0, length($MAGIC)) ne $MAGIC;

    my $offset = length($MAGIC);

    my $read = sub {
        my ($len, $what) = @_;
        die "Corrupt CitronDB file: truncated while reading $what\n"
            if $offset + $len > $total;
        my $chunk = substr($binary, $offset, $len);
        $offset += $len;
        return $chunk;
    };

    my $version = unpack("N", $read->(4, "version"));

    die "CitronDB file version $version is newer than supported version $VERSION\n"
        if $version > $VERSION;
    die "Corrupt CitronDB file: invalid version $version\n"
        if $version < 1;

    my $count = unpack("N", $read->(4, "record count"));

    for (my $i = 0; $i < $count; $i++) {
        my $key = $read->(unpack("N", $read->(4, "key length")), "key");
        my $value = $read->(unpack("N", $read->(4, "value length")), "value");

        # v1 stored raw strings; v2 stores JSON
        if ($version == 1) {
            utf8::decode($value);
            $value = encode_value($value);
        }

        $arr{$key} = $value;
    }

    die "Corrupt CitronDB file: " . ($total - $offset) . " unexpected trailing bytes\n"
        if $offset != $total;

    return \%arr;
}

# --- storage --------------------------------------------------------------

# Runs $code while holding a lock on "<db>.lock". A separate lock file is
# used because writes replace the database file via rename.
sub with_lock {
    my ($mode, $code) = @_;

    open(my $lock, ">>", "$config::file.lock")
        or die "Could not open lock file '$config::file.lock': $!\n";
    flock($lock, $mode)
        or die "Could not lock '$config::file.lock': $!\n";

    return $code->();
}

# The last records read or written, kept so that repeated operations don't
# re-parse the file. It is only reused when the file's bytes are identical
# to the ones it was parsed from, so writes by other processes are always
# seen. `generation` changes whenever the records do; indexes built on top
# (see search_index.perl) use it to know when to rebuild.
my %cache = (raw => undef, records => undef, texts => undef, generation => 0);

sub remember {
    my ($raw, $records) = @_;

    %cache = (raw => $raw, records => $records, texts => undef,
              generation => $cache{generation} + 1);
}

# Returns the records as { key => stored JSON text }. The hash is shared
# with the cache: callers must not modify it.
sub load {
    my $raw = '';
    if (filesystem::file_exists($config::file)) {
        filesystem::open_file($config::file);
        $raw = filesystem::get_data();
    }

    remember($raw, deserialize($raw))
        unless defined $cache{raw} && $cache{raw} eq $raw;

    return $cache{records};
}

sub save {
    my ($arr) = @_;

    my $raw = serialize($arr);
    filesystem::set_data($raw);
    filesystem::write_file($config::file);
    remember($raw, $arr);
}

# Read-modify-write under an exclusive lock. $code gets a copy of the
# records and returns (result, changed); the file is only rewritten when
# changed.
sub modify {
    my ($code) = @_;

    return with_lock(LOCK_EX, sub {
        my $arr = { %{ load() } };
        my ($result, $changed) = $code->($arr);
        save($arr) if $changed;
        return $result;
    });
}

# Runs $code on the records under a shared lock. $code must not modify them.
sub read_only {
    my ($code) = @_;

    return with_lock(LOCK_SH, sub { $code->(load()) });
}

# Read-only snapshot for searching: ({ key => readable text }, generation).
# Both come from the cache, so repeated searches cost one file read and no
# parsing. Callers must not modify the hash.
sub texts {
    return read_only(sub {
        $cache{texts} //= { map { $_ => stored_to_text($_[0]{$_}) } keys %{ $_[0] } };
        return ($cache{texts}, $cache{generation});
    });
}

# Creates the database if missing and removes temp files left by a crash.
sub open_db {
    return with_lock(LOCK_EX, sub {
        filesystem::cleanup_tmp($config::file);

        return 0 if filesystem::file_exists($config::file);

        save({});
        return 1;
    });
}

# --- public API -----------------------------------------------------------

# True if $key already holds $encoded, so a write can be skipped.
sub unchanged {
    my ($arr, $key, $encoded) = @_;
    return defined $arr->{$key} && $arr->{$key} eq $encoded;
}

# Inserts or replaces a key. $value is raw input (JSON or plain text).
sub set_data {
    my ($key, $value) = @_;

    my $encoded = encode_value(parse_value($value));
    $key = to_bytes($key);

    modify(sub {
        my ($arr) = @_;
        return (1, 0) if unchanged($arr, $key, $encoded);
        $arr->{$key} = $encoded;
        return (1, 1);
    });
}

# Replaces an existing key. Returns 0 if the key does not exist.
sub update_data {
    my ($key, $value) = @_;

    my $encoded = encode_value(parse_value($value));
    $key = to_bytes($key);

    return modify(sub {
        my ($arr) = @_;
        return (0, 0) unless exists $arr->{$key};
        return (1, 0) if unchanged($arr, $key, $encoded);
        $arr->{$key} = $encoded;
        return (1, 1);
    });
}

# Removes a key. Returns 0 if the key did not exist.
sub delete_data {
    my ($key) = @_;

    $key = to_bytes($key);

    return modify(sub {
        my ($arr) = @_;
        return (0, 0) unless exists $arr->{$key};
        delete $arr->{$key};
        return (1, 1);
    });
}

sub exists_data {
    my ($key) = @_;

    $key = to_bytes($key);

    return read_only(sub { exists $_[0]->{$key} ? 1 : 0 });
}

# Walks a dotted path ("address.city", "tags.0") into a decoded value.
# Returns (found, value).
sub resolve_path {
    my ($value, $path) = @_;

    return (1, $value) if !defined $path || $path eq '';

    foreach my $part (split(/\./, $path)) {
        if (ref $value eq 'HASH' && exists $value->{$part}) {
            $value = $value->{$part};
        } elsif (ref $value eq 'ARRAY' && $part =~ /^-?\d+$/ && $part < @$value && $part >= -@$value) {
            $value = $value->[$part];
        } else {
            return (0, undef);
        }
    }

    return (1, $value);
}

# Returns (found, decoded value), optionally drilling into a JSON path.
sub lookup {
    my ($key, $path) = @_;

    $key = to_bytes($key);

    my $text = read_only(sub { $_[0]->{$key} });
    return (0, undef) unless defined $text;

    return resolve_path(decode_value($text), $path);
}

# Returns the decoded value, or undef if missing.
sub get_data {
    my ($key, $path) = @_;

    my ($found, $value) = lookup($key, $path);
    return $value;
}

# Readable form of a stored value, same as to_text(decode_value($text)).
# Stored values are canonical JSON::PP output, so only strings with escapes
# need the (slow) decoder: other strings are the bytes between the quotes,
# and non-strings already read as their JSON text.
sub stored_to_text {
    my ($text) = @_;

    return $text if substr($text, 0, 1) ne '"';
    return substr($text, 1, -1) if index($text, "\\") < 0;
    return to_text(decode_value($text));
}

# Returns { key => text } for every record, values in readable form.
sub list {
    my ($texts) = texts();
    return { %$texts };
}

# Returns { key => decoded value } for every record.
sub list_values {
    my $arr = read_only(sub { $_[0] });

    my %data = map { $_ => decode_value($arr->{$_}) } keys %$arr;
    return \%data;
}

sub get_all {
    my $data = list();

    foreach my $key (sort keys %$data) {
        print "$key: $data->{$key}\n";
    }
}

sub print_data {
    my ($key) = @_;

    my ($found, $value) = lookup($key);

    print $found ? to_text($value) . "\n" : "(nil)\n";
}

# Writes every record to $path as a JSON object. Returns the record count.
sub export_json {
    my ($path) = @_;

    my $data = list_values();
    my $pretty = JSON::PP->new->utf8->canonical->pretty;

    open(my $out, ">:raw", $path)
        or die "Could not write '$path': $!\n";
    print $out $pretty->encode($data);
    close($out)
        or die "Could not write '$path': $!\n";

    return scalar keys %$data;
}

# Merges a JSON object from $path into the database in a single write.
# Existing keys are replaced. Returns the record count imported.
sub import_json {
    my ($path) = @_;

    open(my $in, "<:raw", $path)
        or die "Could not read '$path': $!\n";
    my $content = do { local $/; <$in> };
    close($in);

    my $data = eval { $json->decode($content) };
    die "Invalid JSON in '$path': $@" if $@;
    die "'$path' must contain a JSON object at the top level\n"
        unless ref $data eq 'HASH';

    my %encoded = map { to_bytes($_) => encode_value($data->{$_}) } keys %$data;

    return modify(sub {
        my ($arr) = @_;
        @$arr{keys %encoded} = values %encoded;
        return (scalar keys %encoded, 1);
    });
}


# --- snapshots ------------------------------------------------------------

# A snapshot is a full copy of the database file in "<db>.snapshots/",
# stored as "<name>.citron" (so each one is a readable database itself).
# Unnamed snapshots are numbered 1, 2, 3, ... from a counter that only goes
# up, so a number is never reused, even after its snapshot is dropped.
# Named snapshots use letters and digits with at least one letter, so they
# can't collide with the numbers.

sub snapshot_dir {
    return "$config::file.snapshots";
}

sub snapshot_path {
    my ($name) = @_;
    return snapshot_dir() . "/$name.citron";
}

# Any snapshot name, numbered or named. Also keeps names inside the folder.
sub is_snapshot_name {
    my ($name) = @_;
    return defined $name && $name =~ /\A[A-Za-z0-9]+\z/;
}

# Numbers first in order, then names sorted.
sub snapshot_order {
    my ($x, $y) = @_;
    my ($xn, $yn) = map { /\A[0-9]+\z/ ? 1 : 0 } $x, $y;

    return $yn <=> $xn if $xn != $yn;
    return length($x) <=> length($y) || $x cmp $y if $xn;
    return $x cmp $y;
}

sub snapshot_names {
    my $dir = snapshot_dir();
    return () unless -d $dir;

    opendir(my $dh, $dir) or die "Could not read '$dir': $!\n";
    my @names = map { /\A([A-Za-z0-9]+)\.citron\z/ ? $1 : () } readdir($dh);
    closedir($dh);

    return sort { snapshot_order($a, $b) } @names;
}

# Adds one to a decimal string of any length, so numbering never overflows
# or loses precision.
sub increment {
    my ($n) = @_;

    my $i = length($n) - 1;
    while ($i >= 0 && substr($n, $i, 1) eq "9") {
        substr($n, $i, 1, "0");
        $i--;
    }
    return "1$n" if $i < 0;

    substr($n, $i, 1, substr($n, $i, 1) + 1);
    return $n;
}

# Next number: one past the counter, and past any numbered snapshot (in case
# the counter file was lost). Saves the new counter.
sub next_snapshot_number {
    my $counter = snapshot_dir() . "/counter";
    my $last = "0";

    if (-e $counter) {
        filesystem::open_file($counter);
        $last = filesystem::get_data();
        die "Corrupt snapshot counter '$counter'\n" unless $last =~ /\A[0-9]+\z/;
        $last =~ s/\A0+(?=[0-9])//;
    }

    for my $name (snapshot_names()) {
        $last = $name if $name =~ /\A[0-9]+\z/ && snapshot_order($name, $last) > 0;
    }

    my $next = increment($last);
    filesystem::set_data($next);
    filesystem::write_file($counter);
    return $next;
}

# Saves the current data as a snapshot. Without a name it gets the next
# number. Returns the snapshot's name.
sub create_snapshot {
    my ($name) = @_;

    die "Invalid snapshot name '$name': use letters and digits, with at least one letter\n"
        if defined $name && !(is_snapshot_name($name) && $name =~ /[A-Za-z]/);

    return with_lock(LOCK_EX, sub {
        my $records = load();   # refuses a corrupt database
        my $raw = $cache{raw} ne '' ? $cache{raw} : serialize($records);

        my $dir = snapshot_dir();
        mkdir($dir) or -d $dir or die "Could not create '$dir': $!\n";

        if (defined $name) {
            die "Snapshot '$name' already exists\n" if -e snapshot_path($name);
        } else {
            $name = next_snapshot_number();
        }

        filesystem::set_data($raw);
        filesystem::write_file(snapshot_path($name));
        return "$name";
    });
}

# Returns every snapshot name: numbered ones in order, then named ones.
sub list_snapshots {
    return with_lock(LOCK_SH, sub { snapshot_names() });
}

# Replaces the database with a snapshot (the snapshot is kept). Returns 0 if
# there is no such snapshot. A corrupt snapshot is refused and the database
# left untouched.
sub rollback {
    my ($name) = @_;

    return 0 unless is_snapshot_name($name);

    return with_lock(LOCK_EX, sub {
        my $path = snapshot_path($name);
        return 0 unless -e $path;

        filesystem::open_file($path);
        my $raw = filesystem::get_data();
        my $records = eval { deserialize($raw) };
        die "Snapshot '$name' is unusable: $@" if $@;

        filesystem::set_data($raw);
        filesystem::write_file($config::file);
        remember($raw, $records);
        return 1;
    });
}

# Deletes a snapshot. Returns 1 if it existed, else 0.
sub delete_snapshot {
    my ($name) = @_;

    return 0 unless is_snapshot_name($name);

    return with_lock(LOCK_EX, sub {
        my $path = snapshot_path($name);
        return 0 unless -e $path;

        unlink($path) or die "Could not delete '$path': $!\n";
        return 1;
    });
}

666;
