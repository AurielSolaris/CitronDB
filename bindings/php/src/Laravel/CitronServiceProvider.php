<?php

namespace Citron\Laravel;

use Citron\CitronDB;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\ServiceProvider;

/**
 * Registers the "citron" cache driver. Add a store to config/cache.php:
 *
 *     'citron' => [
 *         'driver' => 'citron',
 *         'path' => env('CITRON_CACHE_PATH', storage_path('framework/cache/cache.citron')),
 *     ],
 *
 * Laravel discovers this provider through composer.json; without package
 * discovery, add it to bootstrap/providers.php.
 */
class CitronServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        // Laravel binds the closure to the CacheManager, hence $this.
        Cache::extend('citron', function ($app, array $config) {
            $path = $config['path'] ?? $app->storagePath('framework/cache/cache.citron');
            $dir = dirname($path);

            if (! is_dir($dir) && ! @mkdir($dir, 0777, true) && ! is_dir($dir)) {
                throw new \RuntimeException("Could not create '{$dir}' for the citron cache store");
            }

            return $this->repository(new CitronStore(
                CitronDB::open($path),
                $this->getPrefix($config),
                // cache.serializable_classes, on Laravel versions that have it
                method_exists($this, 'getSerializableClasses') ? $this->getSerializableClasses($config) : null,
            ), $config);
        });
    }
}
