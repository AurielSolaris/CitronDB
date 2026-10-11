<?php

// Tests for the Laravel cache store (Citron\Laravel\CitronStore). They need
// illuminate/cache, illuminate/container and illuminate/config: point
// CITRON_LARAVEL_AUTOLOAD at a vendor/autoload.php that has them, or run
// `composer require --dev illuminate/cache illuminate/container
// illuminate/config` in bindings/php. Without them every test is skipped.
//
//   php test/php/test_laravel.php

declare(strict_types=1);

require __DIR__.'/harness.php';

$autoload = getenv('CITRON_LARAVEL_AUTOLOAD') ?: ROOT.'/bindings/php/vendor/autoload.php';
if (is_file($autoload)) {
    require $autoload;
}
// the binding's own classes, as composer's PSR-4 autoload would find them
spl_autoload_register(function (string $class) {
    if (str_starts_with($class, 'Citron\\')) {
        $file = ROOT.'/bindings/php/src/'.str_replace('\\', '/', substr($class, 7)).'.php';
        if (is_file($file)) {
            require $file;
        }
    }
});

use Citron\CitronDB;
use Citron\Laravel\CitronServiceProvider;
use Citron\Laravel\CitronStore;
use Illuminate\Cache\CacheManager;
use Illuminate\Cache\Repository;
use Illuminate\Config\Repository as Config;
use Illuminate\Container\Container;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Facade;

/** Runs $body with a Laravel cache manager whose "citron" store lives in a temp folder. */
function with_cache(Closure $body): void
{
    if (! class_exists(CacheManager::class)) {
        skip('illuminate/cache not installed (set CITRON_LARAVEL_AUTOLOAD)');
    }

    $dir = temp_dir();
    try {
        $app = new Container;
        $app->instance('config', new Config(['cache' => [
            'default' => 'citron',
            'prefix' => 'app-cache-',
            'stores' => ['citron' => ['driver' => 'citron', 'path' => $dir.'/nested/cache.citron']],
        ]]));
        $app->singleton('cache', fn ($app) => new CacheManager($app));
        Facade::setFacadeApplication($app);
        (new CitronServiceProvider($app))->boot();

        $body($app['cache']->store('citron'), $dir);
    } finally {
        Carbon::setTestNow();
        Facade::clearResolvedInstances();
        remove_tree($dir);
    }
}

function travel(int $seconds): void
{
    Carbon::setTestNow(Carbon::now()->addSeconds($seconds));
}

test('the citron store is registered', fn () => with_cache(function (Repository $cache, string $dir) {
    check($cache->getStore() instanceof CitronStore);
    check(file_exists($dir.'/nested/cache.citron'), 'cache file created');
    check_same('app-cache-', $cache->getStore()->getPrefix());
}));

test('values round trip, binary ones too', fn () => with_cache(function (Repository $cache) {
    $cache->put('pantheon', ['greek' => ['Zeus', 'Hera'], 'count' => 2], 60);
    $cache->forever('binary', "\xff\x00\xfe");

    check_same(['greek' => ['Zeus', 'Hera'], 'count' => 2], $cache->get('pantheon'));
    check_same("\xff\x00\xfe", $cache->get('binary'));
    check_same(['pantheon' => ['greek' => ['Zeus', 'Hera'], 'count' => 2], 'missing' => null],
        $cache->many(['pantheon', 'missing']));
}));

test('the cache file is a normal CitronDB database', fn () => with_cache(function (Repository $cache, string $dir) {
    $cache->forever('greeting', 'hello');
    $db = CitronDB::open($dir.'/nested/cache.citron');
    check_same(['app-cache-greeting'], $db->keys());
    check_same(['e' => 0, 'v' => serialize('hello')], $db->get('app-cache-greeting'));
}));

test('items expire', fn () => with_cache(function (Repository $cache) {
    $cache->put('short', 'lived', 10);
    travel(11);
    check_same(null, $cache->get('short'));
}));

test('add only stores missing or expired items', fn () => with_cache(function (Repository $cache) {
    check($cache->add('key', 'first', 10));
    check(! $cache->add('key', 'second', 10));
    travel(11);
    check($cache->add('key', 'third', 10));
    check_same('third', $cache->get('key'));
}));

test('increment and decrement keep the expiry', fn () => with_cache(function (Repository $cache) {
    $cache->put('counter', 5, 10);
    check_same(8, $cache->increment('counter', 3));
    check_same(6, $cache->decrement('counter', 2));
    travel(11);
    check_same(null, $cache->get('counter'));
    check_same(1, $cache->increment('fresh'));
}));

test('touch extends an item\'s lifetime', fn () => with_cache(function (Repository $cache) {
    $cache->put('key', 'value', 10);
    check($cache->touch('key', 100));
    travel(50);
    check_same('value', $cache->get('key'));
}));

test('forget and flush', fn () => with_cache(function (Repository $cache) {
    $cache->forever('a', 1);
    $cache->forever('b', 2);
    check($cache->forget('a'));
    check_same(null, $cache->get('a'));
    check($cache->flush());
    check_same(null, $cache->get('b'));
}));

test('tags', fn () => with_cache(function (Repository $cache) {
    $cache->tags(['gods'])->put('zeus', 'sky', 60);
    check_same('sky', $cache->tags(['gods'])->get('zeus'));
    $cache->tags(['gods'])->flush();
    check_same(null, $cache->tags(['gods'])->get('zeus'));
}));

test('locks are exclusive and only released by their owner', fn () => with_cache(function (Repository $cache) {
    $lock = $cache->lock('job', 10);
    $other = $cache->lock('job', 10);

    check($lock->get());
    check(! $other->get());
    check(! $other->release());
    check($lock->refresh(20));
    check($lock->release());
    check($other->get());
    $cache->restoreLock('job', $other->owner())->forceRelease();
    check(! $other->isLocked());
}));

exit(run_tests());
