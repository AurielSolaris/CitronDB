require "./src/config.perl";
require "./src/filesystem.perl";
require "./src/citron.perl";

print "Initiating CitronDB...\n";
print "$config::file\n";

if(filesystem::file_exists($config::file)) {
    print "CitronDB already exists\n";
} else {
    filesystem::create_file($config::file);
    print "CitronDB created\n";
}

filesystem::set_data("This is a test string");

filesystem::write_file($config::file);

filesystem::open_file($config::file);

print filesystem::get_data();

print "\n";

print "Test Set Value\n";

citron::set_data("test", "This is a test value");

citron::set_data("test2", "This is a test value 2");

print "test2: ";
citron::print_data("test2");

print "test: ";
citron::print_data("test");

print "\n";