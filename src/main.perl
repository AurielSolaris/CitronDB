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

print "Initiating CitronDB...\n";
print "$config::file\n";

filesystem::cleanup_tmp($config::file);

if(filesystem::file_exists($config::file)) {
    print "CitronDB already exists\n";
} else {
    filesystem::create_file($config::file);
    print "CitronDB created\n";
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

sub handle_command {
    my ($cmd, $key, $value) = @_;

    if($cmd eq "set") {
        citron::set_data($key, $value);
        print "Set $key to $value\n";
    } elsif($cmd eq "get") {
        my $result = citron::get_data($key);
        print "$key: $result\n";
    } elsif($cmd eq "update") {
        citron::update_data($key, $value);
        print "Updated $key to $value\n";
    } elsif($cmd eq "delete") {
        citron::delete_data($key);
        print "Deleted $key\n";
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
    } elsif($cmd eq "help") {
        print "Commands: set <key> <value>, get <key>, update <key> <value>, delete <key>, list, search <string> <type|default=binary>, mapreduce <job>, exit\n";
    } elsif($cmd eq "exit") {
        print "Goodbye.\n";
        exit 0;
    } else {
        print "Unknown command '$cmd'. Type 'help' for commands.\n";
    }
}

if(cli::arguments(0)) {
    handle_command(cli::arguments(0), cli::arguments(1), cli::arguments(2));
} else {
    print "CitronDB v0.3 — type 'help' for commands\n";
    while(1) {
        print "citron> ";
        my $input = <STDIN>;
        chomp $input;
        next if $input eq '';

        my ($cmd, $key, $value) = split(/\s+/, $input, 3);
        handle_command($cmd, $key, $value);
    }
}