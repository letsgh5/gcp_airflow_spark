from datetime import datetime

from airflow import DAG
from airflow.models.param import Param
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator


def _download_from_gcs(bucket: str, analityk_id: str, script_name: str, run_dir: str) -> None:
    import json
    import os
    import urllib.request

    os.makedirs(run_dir, exist_ok=True)

    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1"
        "/instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"},
    )
    token = json.loads(urllib.request.urlopen(req).read())["access_token"]

    blob = f"dags/{analityk_id}/{script_name}".replace("/", "%2F")
    url = f"https://storage.googleapis.com/download/storage/v1/b/{bucket}/o/{blob}?alt=media"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    data = urllib.request.urlopen(req).read()

    open(f"{run_dir}/{script_name}", "wb").write(data)
    print(f"Pobrano {len(data):,} B → {run_dir}/{script_name}")


with DAG(
    dag_id="admin_run_script",
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    params={
        "analityk_id": Param("analityk01", type="string", description="Login analityka"),
        "script_name": Param("script.py", type="string", description="Nazwa pliku w GCS"),
    },
    tags=["admin"],
    # Widoczny tylko dla admina — analitycy mają własne DAGi run_script_analitykXX
    access_control={
        "Admin": {"can_read", "can_edit", "can_delete"},
    },
) as dag:

    download = PythonOperator(
        task_id="download_from_gcs",
        python_callable=_download_from_gcs,
        op_kwargs={
            "bucket": "{{ var.value.get('dag_bucket', '') }}",
            "analityk_id": "{{ params.analityk_id }}",
            "script_name": "{{ params.script_name }}",
            "run_dir": "/tmp/analityk_run_{{ ts_nodash }}",
        },
    )

    run = BashOperator(
        task_id="run_script",
        env={
            "SCRIPT": "{{ params.script_name }}",
            "RUN_DIR": "/tmp/analityk_run_{{ ts_nodash }}",
        },
        append_env=True,
        bash_command="cd $RUN_DIR && python3 $SCRIPT",
    )

    cleanup = BashOperator(
        task_id="cleanup",
        env={"RUN_DIR": "/tmp/analityk_run_{{ ts_nodash }}"},
        append_env=True,
        bash_command="rm -rf $RUN_DIR",
        trigger_rule="all_done",
    )

    download >> run >> cleanup
