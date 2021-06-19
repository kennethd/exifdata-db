/*
 * exifdata.sql creates schema for exifdata.db
 * exifdata.sh populates & queries the schema
 */

PRAGMA encoding = 'UTF-8';

CREATE TABLE IF NOT EXISTS exifdata (
    md5 VARCHAR(32) NOT NULL,
    path VARCHAR(255) NOT NULL,
    bytes INTEGER NOT NULL,
    dtcreated VARCHAR(24), /* ISO-8601. allow null in case no exif data */
    exifhash VARCHAR(32), 
    exifdata BLOB,
    PRIMARY KEY (md5, path)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS md5 ON exifdata (md5);
CREATE INDEX IF NOT EXISTS path ON exifdata (path);
CREATE INDEX IF NOT EXISTS exifhash ON exifdata (exifhash);
CREATE INDEX IF NOT EXISTS bytes ON exifdata (bytes);
CREATE INDEX IF NOT EXISTS dtcreated ON exifdata (dtcreated);
