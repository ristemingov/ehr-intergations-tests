import requests
import time
import random
import uuid
import json


STATUSES = ["received", "processing", "completed", "error"]

def generate_fhir_patient(index: int) -> dict:
    return {
        "resourceType": "Patient",
        "id": str(uuid.uuid4()),
        "name": [{
            "use": "official",
            "family": f"Doe{index}",
            "given": [f"John{index}"]
        }],
        "gender": random.choice(["male", "female"]),
        "birthDate": f"198{index % 10}-0{(index % 9) + 1}-15"
    }

def send_log(status: str, message: str, workflow_id: str, base_url: str = "http://0.0.0.0:8000"):
    url = f"{base_url}/logs/"
    payload = {
        "status": status,
        "message": message,
        "workflow_id": workflow_id
    }
    headers = {
        "accept": "application/json",
        "Content-Type": "application/json"
    }

    response = requests.post(url, json=payload, headers=headers)
    print(f"{status.upper()} | {response.status_code} | {response.text}")

def send_multiple_logs(count: int = 100, workflow_id: str = "wf_123"):
    for i in range(count):
        status = random.choice(STATUSES)
        patient_dict = generate_fhir_patient(i + 1)
        message = json.dumps(patient_dict)
        send_log(status, message, workflow_id, base_url="https://app.lokahealthlink.lokadevops.com/")
        time.sleep(0.1)  # Optional small delay between requests

# Run 100 logs
send_multiple_logs(10, "8805f7fb-13d3-4f44-8bf4-4d562bb5e885")
