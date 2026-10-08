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

sub load {
    return {} unless filesystem::file_exists($config::file);

    filesystem::open_file($config::file);
    return deserialize(filesystem::get_data());
}

sub save {
    my ($arr) = @_;

    filesystem::set_data(serialize($arr));
    filesystem::write_file($config::file);
}

# Read-modify-write under an exclusive lock. $code gets the records and
# returns (result, changed); the file is only rewritten when changed.
sub modify {
    my ($code) = @_;

    return with_lock(LOCK_EX, sub {
        my $arr = load();
        my ($result, $changed) = $code->($arr);
        save($arr) if $changed;
        return $result;
    });
}

sub read_only {
    my ($code) = @_;

    return with_lock(LOCK_SH, sub { $code->(load()) });
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

# Inserts or replaces a key. $value is raw input (JSON or plain text).
sub set_data {
    my ($key, $value) = @_;

    my $encoded = encode_value(parse_value($value));
    $key = to_bytes($key);

    modify(sub {
        my ($arr) = @_;
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

# Returns { key => text } for every record, values in readable form.
sub list {
    my $arr = read_only(sub { $_[0] });

    my %data = map { $_ => to_text(decode_value($arr->{$_})) } keys %$arr;
    return \%data;
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

666;
