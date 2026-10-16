import os
from datetime import datetime, timezone

from google.cloud import bigquery
from google.cloud import compute_v1

EXECUTION_PROJECT = os.getenv("EXECUTION_PROJECT", "gcp-prod-edp-edge-509423")
TARGET_PROJECT = os.getenv("TARGET_PROJECT", "pjt-c-admin")
TARGET_DATASET = os.getenv("TARGET_DATASET", "dlk_sample")
TARGET_TABLE = os.getenv("TARGET_TABLE", "gcp_region_inventory")


def fetch_gcp_regions() -> list[dict]:
    client = compute_v1.RegionsClient()
    loaded_at = datetime.now(timezone.utc).isoformat()
    rows = []

    for region in client.list(project=EXECUTION_PROJECT):
        rows.append(
            {
                "region_name": region.name,
                "status": region.status,
                "description": region.description or "",
                "self_link": region.self_link,
                "zones": [zone.rsplit("/", 1)[-1] for zone in region.zones],
                "loaded_at": loaded_at,
            }
        )

    return rows


def write_to_bigquery(rows: list[dict]) -> None:
    client = bigquery.Client(project=EXECUTION_PROJECT)
    destination = f"{TARGET_PROJECT}.{TARGET_DATASET}.{TARGET_TABLE}"

    schema = [
        bigquery.SchemaField("region_name", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("status", "STRING"),
        bigquery.SchemaField("description", "STRING"),
        bigquery.SchemaField("self_link", "STRING"),
        bigquery.SchemaField("zones", "STRING", mode="REPEATED"),
        bigquery.SchemaField("loaded_at", "TIMESTAMP", mode="REQUIRED"),
    ]

    job_config = bigquery.LoadJobConfig(
        schema=schema,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )

    print(f"Loading {len(rows)} GCP regions into {destination}")
    job = client.load_table_from_json(rows, destination, job_config=job_config)
    job.result()
    table = client.get_table(destination)
    print(f"Completed: {destination}, rows={table.num_rows}")


def main() -> None:
    rows = fetch_gcp_regions()
    if not rows:
        raise RuntimeError("No GCP region data returned")
    write_to_bigquery(rows)


if __name__ == "__main__":
    main()
