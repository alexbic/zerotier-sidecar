# Branch Unification Notes

## v2.1.0 (2025-11-01)

As of v2.1.0, the `gateway` and `main` branches have been successfully unified.

### What Changed

- **Single Production Branch**: `main` now contains all v2.x functionality
- **Docker Tag Updates**: `:latest` now points to v2.x (all features)
- **Legacy Support**: v1.x available via `:core` and `:v1.1.1` tags

### For Users

- **Upgrading**: Simply use `:latest` tag instead of `:gateway`
- **Staying on v1.x**: Use `:core` or `:v1.1.1` tags
- **No Breaking Changes**: All v1.x configurations work in v2.x

See the [README](../README.md) for detailed migration information.
