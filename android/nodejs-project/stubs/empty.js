// Stands in for the native database drivers (pg, better-sqlite3) when the
// server is bundled for Android. The app always uses the local filesystem
// database, so the modules that import these drivers never call them.
module.exports = {};
