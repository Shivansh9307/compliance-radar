"""
Load the Companies House 'Free Company Data Product' bulk CSV(s)
into the bronze.companies_raw table.

Usage:
    python ingestion/load_bulk.py            # load everything (takes a while)
    python ingestion/load_bulk.py --sample   # load only 10,000 rows to test first
"""
import os
import sys
import glob
import pandas as pd
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

load_dotenv()  # reads DATABASE_URL from your .env file

DATABASE_URL = os.environ["DATABASE_URL"]
DATA_GLOB = "data/**/BasicCompanyData*.csv"   # matches split or single-file downloads
CHUNK_SIZE = 50_000
SCHEMA = "bronze"
TABLE = "companies_raw"


def clean_columns(cols):
    # Companies House headers have stray spaces and dots (e.g. " RegAddress.PostCode")
    return (
        cols.str.strip()
            .str.lower()
            .str.replace(".", "_", regex=False)
            .str.replace(" ", "_", regex=False)
    )


def main(sample=False):
    engine = create_engine(DATABASE_URL)

    files = sorted(glob.glob(DATA_GLOB, recursive=True))
    if not files:
        sys.exit(f"No files matched {DATA_GLOB}. Did you unzip the download into data/ ?")
    print(f"Found {len(files)} file(s) to load.")

    # Start clean so re-running the script never creates duplicate rows.
    with engine.begin() as conn:
        conn.execute(text(f"DROP TABLE IF EXISTS {SCHEMA}.{TABLE}"))

    total = 0
    first_write = True
    for f in files:
        print(f"Reading {f} ...")
        reader = pd.read_csv(
            f,
            chunksize=CHUNK_SIZE,
            dtype=str,          # keep everything as text in the raw (bronze) layer
            low_memory=False,
            nrows=10_000 if sample else None,
        )
        for chunk in reader:
            chunk.columns = clean_columns(chunk.columns)
            chunk.to_sql(
                TABLE, engine, schema=SCHEMA,
                if_exists="replace" if first_write else "append",
                index=False,
            )
            first_write = False
            total += len(chunk)
            print(f"  loaded {total:,} rows", end="\r")

    print(f"\nDone. {total:,} rows in {SCHEMA}.{TABLE}")


if __name__ == "__main__":
    main(sample="--sample" in sys.argv)