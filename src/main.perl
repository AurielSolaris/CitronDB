require "./src/config.perl";
require "./src/filesystem.perl";
require "./src/citron.perl";
require "./src/cli.perl";
require "./src/search_binary.perl";
require "./src/search_regex.perl";
require "./src/search_fuzzy.perl";
require "./src/search_prefix.perl";
require "./src/search_suffix.perl";
require "./src/search_levenshtein.perl";
require "./src/search_soundex.perl";
require "./src/search_substring.perl";
require "./src/mapreduce.perl";

$config::file = cli::flag("file") if cli::flag("file");

print "Initiating CitronDB...\n";
print "$config::file\n";

my $created = eval { citron::open_db() };

if($@) {
    print "(error) $@";
    exit 1;
} elsif($created) {
    print "CitronDB created\n";
} else {
    print "CitronDB already exists\n";
}
sub handle_search {
    my ($pattern, $type) = @_;
    $type //= "binary";

    my $results;

    if($type eq "binary") {
        $results = search_binary::search_pairs($pattern);
    } elsif($type eq "regex") {
        $results = search_regex::search_pairs($pattern);
    } elsif($type eq "fuzzy") {
        $results = search_fuzzy::search_pairs($pattern);
    } elsif($type eq "prefix") {
        $results = search_prefix::search_pairs($pattern);
    } elsif($type eq "suffix") {
        $results = search_suffix::search_pairs($pattern);
    } elsif($type eq "levenshtein") {
        $results = search_levenshtein::search_pairs($pattern);
    } elsif($type eq "soundex") {
        $results = search_soundex::search_pairs($pattern);
    } elsif($type eq "substring") {
        $results = search_substring::search_pairs($pattern);
    } else {
        print "Unknown search type '$type'. Types: binary, regex, fuzzy, prefix, suffix, levenshtein, soundex, substring\n";
        return;
    }

    if(scalar keys %$results == 0) {
        print "No results found.\n";
    } else {
        search_binary::print_results($results);
    }
}

my %usage = (
    set       => "set <key> <value>",
    get       => "get <key> [path]",
    update    => "update <key> <value>",
    delete    => "delete <key>",
    exists    => "exists <key>",
    search    => "search <string> [type]",
    mapreduce => "mapreduce <job>",
    export    => "export <file.json>",
    import    => "import <file.json>",
);

sub run_command {
    my ($cmd, $key, $value) = @_;

    if($usage{$cmd} && !defined $key) {
        print "(error) usage: $usage{$cmd}\n";
        return;
    }

    if(($cmd eq "set" || $cmd eq "update") && !defined $value) {
        print "(error) usage: $usage{$cmd}\n";
        return;
    }

    if($cmd eq "set") {
        citron::set_data($key, $value);
        print "OK\n";
    } elsif($cmd eq "get") {
        my ($found, $result) = citron::lookup($key, $value);
        print $found ? citron::to_text($result) . "\n" : "(nil)\n";
    } elsif($cmd eq "update") {
        if(citron::update_data($key, $value)) {
            print "OK\n";
        } else {
            print "(error) no such key '$key' (use set to create it)\n";
        }
    } elsif($cmd eq "delete") {
        print "(integer) ", citron::delete_data($key), "\n";
    } elsif($cmd eq "exists") {
        print "(integer) ", citron::exists_data($key), "\n";
    } elsif($cmd eq "list") {
        citron::get_all();
    } elsif($cmd eq "search") {
        handle_search($key, $value);
    } elsif($cmd eq "mapreduce") {
        my $results = mapreduce::run_job($key);

        if(!defined $results) {
            print "Unknown job '$key'. Jobs: ", join(", ", mapreduce::job_names()), "\n";
        } elsif(scalar keys %$results == 0) {
            print "No results found.\n";
        } else {
            mapreduce::print_results($results);
        }
    } elsif($cmd eq "export") {
        my $count = citron::export_json($key);
        print "Exported $count records to $key\n";
    } elsif($cmd eq "import") {
        my $count = citron::import_json($key);
        print "Imported $count records from $key\n";
    } elsif($cmd eq "help") {
        print "Commands: ", join(", ", (map { $usage{$_} } qw(set get update delete exists search mapreduce export import)), "list", "exit"), "\n";
        print "Values are JSON (e.g. {\"name\":\"Ada\"}, [1,2], 42, true); anything else is stored as a string.\n";
        print "Paths reach into JSON values: get user:1 address.city, get user:1 tags.0\n";
    } elsif($cmd eq "exit") {
        print "Goodbye.\n";
        exit 0;
    } else {
        print "Unknown command '$cmd'. Type 'help' for commands.\n";
    }
}

# Errors (corrupt file, bad import, I/O failure) are reported without
# killing the REPL.
sub handle_command {
    eval { run_command(@_); 1 } or print "(error) $@";
}

if(defined cli::arguments(0)) {
    handle_command(cli::arguments(0), cli::arguments(1), cli::arguments(2));
} else {
    print "CitronDB v0.5.1 — type 'help' for commands\n";
    while(1) {
        print "citron> ";
        my $input = <STDIN>;
        last unless defined $input;
        chomp $input;
        $input =~ s/^\s+|\s+$//g;
        next if $input eq '';

        my ($cmd, $key, $value) = split(/\s+/, $input, 3);
        handle_command($cmd, $key, $value);
    }
}
