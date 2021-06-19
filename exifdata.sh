#!/bin/sh

# 2021-06-17 kld
# written on Ubuntu w/dash shell

usage() {
    cat <<-END
	$0 [OPTIONS]

	This script is designed to *not* be portable; but very specifically to
	be run from my Dropbox/Photos directory for the purpose of identifying
	duplicate files for cleanup

	  -h or --help 	      Display this message and exit
	  -v or --verbose     Be verbose
	  -d or --dump        Dump database to file in the form of SQL commands
	  -D or --drop        Drop database before re-creating
	  -i or --ingest-dir  Directory to ingest
	  -I or --ingest-file JPEG file to ingest
	  -l or --log         Create log of actions
	  --list-duplicates   Queries database for duplicate md5sums
	  --purge-dupes-from  Requires path prefix for copy of dupe to delete;
	                      for any pair of dupes, the one whose path attribute
	                      matches the argument will be deleted
	  --rm-file           Accepts path to remove from both disk & db

	If --dump is specified it will create a dump of any existing data BEFORE
	running any further commands. This is good for creating a backup of any
	existing data before running any other commands.
END
}

SHORTOPTS='dDf:hi:I:lv'
LONGOPTS='drop,dump,file:,help,ingest-dir:,ingest-file:,list-duplicates,log,purge-dupes-from:,rm-file:,verbose'
ARGS=$(getopt -o $SHORTOPTS --long $LONGOPTS -- "$@") || exit
eval "set -- $ARGS"

DBFILE="./exifdata.db"  # let dropbox keep a copy of this synced w/Photos dir
TMPDB="/tmp/exifdata-temp.db"
while true; do
  case $1 in
    -h | --help)
      usage
      shift; exit 0;;
    -v | --verbose)
      VERBOSE=1; shift;;
    -D | --drop)
      DROP=1; shift;;
    -d | --dump)
      DUMP=1; shift;;
    -f | --file)
      FILE=$2; shift;
      shift;;
    -i | --ingest-dir)
      INGEST_DIR=$2; shift;
      shift;;
    -I | --ingest-file)
      INGEST_FILE=$2; shift;
      shift;;
    -l | --log)
      LOG=1; shift;;
    --list-duplicates)
      LIST_DUPLICATES=1; shift;;
    --purge-dupes-from)
      PURGE_DUPES_FROM="$2"; shift;
      shift;;
    --rm-file)
      RM_FILE="$2"; shift;
      shift;;
    --)
      shift; break;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1;;
  esac
done

if [ -n "$VERBOSE" ]; then
    echo DROP="$DROP"
    echo DUMP="$DUMP"
    echo DBFILE="$DBFILE"
    echo TMPDB="$TMPDB"
    echo INGEST_DIR="$INGEST_DIR"
    echo INGEST_FILE="$INGEST_FILE"
    echo LOG="$LOG"
    echo LIST_DUPLICATES="$LIST_DUPLICATES"
    echo PURGE_DUPES_FROM="$PURGE_DUPES_FROM"
    echo RM_FILE="$RM_FILE"
    echo unknown args="$@"
    set -x
fi

DBFILE_OPTS="-bail $DBFILE"
if [ -n "$VERBOSE" ]; then
    DBFILE_OPTS="-echo $DBFILE_OPTS"
fi
if [ -n "$LOG" ]; then
    CMD_OPTS=".trace ./exifdata.log"
fi

createdb() {
    sqlite3 $DBFILE_OPTS "$CMD_OPTS" ".read ./exifdata.sql"
    sqlite3 $TMPDB "$CMD_OPTS" ".read ./exifdata-temp.sql"
}

dropdb() {
    rm "$FILE"
}

dumpdb() {
    sqlite3 $DBFILE_OPTS "$CMD_OPTS" ".output exifdata.dump" ".dump"
}

insertrow() {
    SQL="INSERT INTO exifdata (md5, path, bytes, dtcreated, exifhash, exifdata)"
    SQL="$SQL VALUES (:md5, :path, :bytes, :dtcreated, :exifhash, :exifdata)"
    sqlite3 $DBFILE_OPTS "$CMD_OPTS" \
        ".param init" \
        ".param set :md5 $1" \
        ".param set :path '$2'" \
        ".param set :bytes $3" \
        ".param set :dtcreated '$4'" \
        ".param set :exifhash $5" \
        ".param set :exifdata '$6'" \
        "$SQL" \
        ".param clear"
}

insert_purge_record() {
    SQL="INSERT INTO purge_records (purge, md5, path, bytes, dtcreated, exifhash)"
    SQL="$SQL VALUES (:purge, :md5, :path, :bytes, :dtcreated, :exifhash)"
    sqlite3 $TMPDB "$CMD_OPTS" \
        ".param init" \
        ".param set :purge $1" \
        ".param set :md5 $2" \
        ".param set :path '$3'" \
        ".param set :bytes $4" \
        ".param set :dtcreated '$5'" \
        ".param set :exifhash $6" \
        "$SQL" \
        ".param clear"
}

ingestfile() {
    MD5=$( md5sum "$1" | cut -d ' ' -f 1 | tr -d '\n' )
    BYTES=$( ls -l "$1" | cut -d ' ' -f 5 | tr -d '\n' )
    # orig created date as recorded in exif data, not filesystem timestamp
    CREATED=$( exif -t 0x9003 "$1" | grep Value: | awk '{ print $2" "$3 }' | tr -d '\n' )
    # `tail -n +2` skips fist line, a header w/filename
    EXIFHASH=$( exif "$1" | tail -n +2 | md5sum | cut -d' ' -f1 | tr -d '\n' )
    EXIFDATA=$( exif "$1" | tail -n +2 )
    insertrow "$MD5" "$1" "$BYTES" "$CREATED" "$EXIFHASH" "$EXIFDATA"
}

ingestdir() {
    local IFS="
"
    for F in $( find "$1" -iname '*.jpg' ); do
        ingestfile "$F"
    done
}

DUPES_SQL="SELECT ex.md5, ex.path, ex.bytes, ex.dtcreated, ex.exifhash, grp.cnt"
DUPES_SUBQ="SELECT md5, COUNT(*) AS cnt FROM exifdata GROUP BY md5 HAVING cnt > 1"
DUPES_SQL="$DUPES_SQL FROM exifdata AS ex, ($DUPES_SUBQ) AS grp"
DUPES_SQL="$DUPES_SQL WHERE ex.md5 = grp.md5 AND grp.cnt IS NOT NULL"
DUPES_SQL="$DUPES_SQL ORDER BY ex.md5, ex.path;"

listdupes() {
    sqlite3 "$DBFILE" ".mode column" ".width 32 64 9 18 32 4" "$DUPES_SQL"
}

purgedupes() {
    local PURGE_DUPES_FROM="$1"
    local IFS="
"
    sqlite3 "$DBFILE" ".mode line" "$DUPES_SQL" | while read field; do
        # $field input will be something like '   column  =  value   ', it is piped to awk
        # split($0, kv, "=") splits STDIN on "=" char & assigns results to array kv
        # for(i in kv) iterates over all keys in array kv, assigning them to i
        # gsub(/.../, "", kv[i]) performs regex substitution on array value;
        # regex /^[ \t]+|[ \t]+$/ matches leading & trailing space, replacing it with empty string
        # final print statement prints updated key & value, separated by ,
        local kv=$(echo "$field"|awk '{split($0,kv,"="); for (i in kv) {gsub(/^[ \t]+|[ \t]+$/,"",kv[i])}; print kv[1]","kv[2]}')
        # kv="exifhash,Path to Collection/Foto #1, taken by Ken.jpg"
        k=${kv%,*}  # exifhash
        v=${kv#*,}  # Path to Collection/Foto #1, taken by Ken.jpg
        case $k in
          md5)
            md5="$v"
            ;;
          path)
            path="$v"
            if [ "$v" != "${v#$PURGE_DUPES_FROM}" ]; then
                # prefix matched, purge this one
                purge=Delete
            else
                purge=Keep
            fi
            ;;
          bytes)
            bytes="$v"
            ;;
          dtcreated)
            dtcreated="$v"
            ;;
          exifhash)
            exifhash="$v"
            ;;
        esac 
        # have we exhausted all records for $old_md5?
        if [ "$md5" ] && [ "$old_md5" ] && [ "$md5" != "$old_md5" ]; then
            prompt_user_to_delete "$old_md5"
        fi
        # have we seen a complete record?
        if [ "$md5" ] && [ "$path" ] && [ "$purge" ] && [ "$bytes" ] && [ "$dtcreated" ] && [ "$exifhash" ]; then
            old_md5="$md5"
            insert_purge_record "$purge" "$md5" "$path" "$bytes" "$dtcreated" "$exifhash"
            unset md5 path purge bytes dtcreated exifhash
        fi
    done
}

prompt_user_to_delete() {
    MD5="$1"
    local IFS="
"
    local SQL="SELECT * FROM purge_records WHERE md5 = :md5"
    local seen_records=0
    local seen_purgeable_records=0
    echo ""
    # Note: the construct commented here does not work due to the issue described @
    # https://stackoverflow.com/questions/15390635/bash-script-variable-scope-issue
    # in short: putting the `while read` loop in the RHS of pipe puts it in subshell
    #sqlite3 $TMPDB ".mode line" ".param init" ".param set :md5 $MD5" "$SQL" ".param clear" | while read field; do ... done
    while read field; do
        case "$field" in
          *md5*)
            seen_records=$(($seen_records+1))
            ;;
          *purge*=*Delete*)
            seen_purgeable_records=$(($seen_purgeable_records+1))
            ;;
        esac
        echo "\t$seen_records: $field"
        echo "\trecords seen: $seen_records purgeable: $seen_purgeable_records"
    done < $(sqlite3 $TMPDB ".mode line" ".param init" ".param set :md5 $MD5" "$SQL" ".param clear")
    echo "\n\trecords seen: $seen_records purgeable: $seen_purgeable_records\n"
    if [ "$seen_purgeable_records" = "0" ]; then
        echo "\n\tNo records flagged for deletion ($seen_purgeable_records)\n"
        # Do you want to allow both copies to remain on disk?
        read -p "Continue? " yn < /dev/tty
        case $yn in
          n* | N*)
            # Which shall I delete?
            echo "Goodbye."
            exit 0
            ;;
          y* | Y*)
            # Removing from duplicates table.
            # Reingesting the directory will cause them to reappear.
            return
            ;;
          *)
            echo "Unrecognized response."
            return
            ;;
        esac 
    elif [ "$seen_purgeable_records" = "$seen_records" ]; then
        echo "\n\tWARNING: all records matching md5 are marked for deletion\n"
    else
        echo "\n\tWe have both purgeable record(s) and non-purgeable record(s)\n"
    fi
    read -p "Delete files flagged to purge? " yn < /dev/tty
    case $yn in
      n* | N*)
        echo "Not deleting. Moving on."
        # return control to caller
        return
        ;;
      y* | Y*)
        delete_flagged_purgeable "$1"
        ;;
      *)
        echo "Unrecognized response. Exiting"
        exit 1
        ;;
    esac 
}

rmfile() {
    rm "$1"
    local SQL="DELETE FROM exifdata WHERE path = :path"
    sqlite3 $DBFILE "$CMD_OPTS" \
        ".param init" \
        ".param set :path '$1'" \
        "$SQL" \
        ".param clear"
}

if [ -n "$DUMP" ]; then
    dumpdb
fi
if [ -n "$DROP" ]; then
    dropdb
fi
# createdb is a noop if already exists
createdb
sqlite3 "$DBFILE" ".tables" ".indices"
sqlite3 "$TMPDB" ".tables" ".indices"
if [ -n "$INGEST_DIR" ]; then
    ingestdir "$INGEST_DIR"
fi
if [ -n "$INGEST_FILE" ]; then
    ingestfile "$INGEST_FILE"
fi
if [ -n "$RM_FILE" ]; then
    rmfile "$RM_FILE"
fi
if [ -n "$PURGE_DUPES_FROM" ]; then
    purgedupes "$PURGE_DUPES_FROM"
fi
if [ -n "$LIST_DUPLICATES" ]; then
    listdupes
fi

exit 0
