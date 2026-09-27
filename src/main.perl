require "./src/config.perl";
require "./src/filesystem.perl";
require "./src/citron.perl";
require "./src/cli.perl";

print "Initiating CitronDB...\n";
print "$config::file\n";

if(filesystem::file_exists($config::file)) {
    print "CitronDB already exists\n";
} else {
    filesystem::create_file($config::file);
    print "CitronDB created\n";
}

sub handle_command {
    my ($cmd, $key, $value) = @_;

    if($cmd eq "set") {
        citron::set_data($key, $value);
        print "Set $key to $value\n";
    } elsif($cmd eq "get") {
        my $result = citron::get_data($key);
        print "$key: $result\n";
    } elsif($cmd eq "help") {
        print "Commands: set <key> <value>, get <key>, exit\n";
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
    print "CitronDB v0.1 — type 'help' for commands\n";
    while(1) {
        print "citron> ";
        my $input = <STDIN>;
        chomp $input;
        next if $input eq '';

        my ($cmd, $key, $value) = split(/\s+/, $input, 3);
        handle_command($cmd, $key, $value);
    }
}