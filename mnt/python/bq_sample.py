#!/usr/bin/env python3
import os

from google.cloud import bigquery

JOB_PROJECT = os.getenv("BQ_JOB_PROJECT", "gcp-prod-edp-edge-509423")
TABLE = os.getenv(
    "BQ_SAMPLE_TABLE",
    "pjt-c-admin.dlk_sample.gcp_region_inventory",
)
LIMIT = int(os.getenv("BQ_SAMPLE_LIMIT", "10"))


def main() -> None:
    client = bigquery.Client(project=JOB_PROJECT)

    sql = f"""
    SELECT
      region_name,
      status,
      description,
      loaded_at
    FROM `{TABLE}`
    ORDER BY region_name
    LIMIT {LIMIT}
    """

    print(f"[INFO] BigQuery job project : {JOB_PROJECT}")
    print(f"[INFO] Sample table         : {TABLE}")
    print(f"[INFO] Limit                : {LIMIT}")
    print()

    rows = list(client.query(sql).result())

    print(f"[INFO] rows={len(rows)}")
    for row in rows:
        print(
            f"{row.region_name}\t"
            f"{row.status}\t"
            f"{row.description}\t"
            f"{row.loaded_at}"
        )


if __name__ == "__main__":
    main()
