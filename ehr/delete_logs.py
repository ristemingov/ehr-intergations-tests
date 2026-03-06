import requests

BASE_URL = "https://app.lokahealthlink.lokadevops.com/"
HEADERS = {
    "accept": "application/json"
}

def list_logs():
    response = requests.get(f"{BASE_URL}/logs", headers=HEADERS)
    if response.status_code == 200:
        return response.json()
    else:
        print(f"Failed to list logs: {response.status_code}")
        return []

def delete_log(log_id: str):
    response = requests.delete(f"{BASE_URL}/logs/{log_id}", headers=HEADERS)
    print(f"DELETE {log_id} | {response.status_code} | {response.text}")

def delete_all_logs():
    logs = list_logs()
    if not logs:
        print("No logs to delete.")
        return
    for log in logs:
        log_id = log.get("id")
        if log_id:
            delete_log(log_id)

# Run the cleanup
delete_all_logs()
