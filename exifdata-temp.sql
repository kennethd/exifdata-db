PRAGMA encoding = 'UTF-8';

CREATE TABLE IF NOT EXISTS purge_records (
    md5 VARCHAR(32) NULL,
    purge VARCHAR(6) NULL,
    path VARCHAR(255) NULL,
    bytes INTEGER NULL,
    dtcreated VARCHAR(24) NULL,
    exifhash VARCHAR(32) NULL,
    PRIMARY KEY (md5, path)
) WITHOUT ROWID;
