import requests
import json
import random
from datetime import datetime, timedelta

FHIR_BASE = "http://localhost:8081"
NUM_PATIENTS = 100
ENCOUNTERS_PER_PATIENT = 2
OBSERVATIONS_PER_ENCOUNTER = 2

HEADERS = {"Content-Type": "application/fhir+json"}

def post_resource(resource_type, body):
    url = f"{FHIR_BASE}/{resource_type}"
    r = requests.post(url, headers=HEADERS, data=json.dumps(body))
    if r.status_code in [200, 201]:
        return r.json()["id"]
    else:
        print(f"❌ Failed to post {resource_type}: {r.status_code} {r.text}")
        return None

def generate_patient(index):
    return {
        "resourceType": "Patient",
        "name": [{"use": "official", "family": f"Doe-{index}", "given": [f"John-{index}"]}],
        "gender": random.choice(["male", "female"]),
        "birthDate": f"{random.randint(1950, 2010)}-01-01"
    }

def generate_encounter(patient_id):
    start = datetime.now() - timedelta(days=random.randint(100, 1000))
    end = start + timedelta(hours=1)
    return {
        "resourceType": "Encounter",
        "status": "finished",
        "class": {"system": "http://terminology.hl7.org/CodeSystem/v3-ActCode", "code": "AMB"},
        "subject": {"reference": f"Patient/{patient_id}"},
        "period": {"start": start.isoformat(), "end": end.isoformat()}
    }

def generate_observation(patient_id, encounter_id):
    return {
        "resourceType": "Observation",
        "status": "final",
        "code": {"coding": [{"system": "http://loinc.org", "code": "29463-7", "display": "Body weight"}]},
        "subject": {"reference": f"Patient/{patient_id}"},
        "encounter": {"reference": f"Encounter/{encounter_id}"},
        "valueQuantity": {"value": round(random.uniform(60, 100), 1), "unit": "kg"},
        "effectiveDateTime": datetime.now().isoformat()
    }

def generate_condition(patient_id, encounter_id):
    return {
        "resourceType": "Condition",
        "subject": {"reference": f"Patient/{patient_id}"},
        "encounter": {"reference": f"Encounter/{encounter_id}"},
        "code": {"coding": [{"system": "http://snomed.info/sct", "code": "44054006", "display": "Diabetes mellitus type 2"}]},
        "clinicalStatus": {"coding": [{"system": "http://terminology.hl7.org/CodeSystem/condition-clinical", "code": "active"}]},
        "onsetDateTime": datetime.now().isoformat()
    }

def generate_procedure(patient_id, encounter_id):
    return {
        "resourceType": "Procedure",
        "status": "completed",
        "subject": {"reference": f"Patient/{patient_id}"},
        "encounter": {"reference": f"Encounter/{encounter_id}"},
        "code": {"coding": [{"system": "http://snomed.info/sct", "code": "80146002", "display": "Appendectomy"}]},
        "performedDateTime": datetime.now().isoformat()
    }

def generate_allergy(patient_id):
    return {
        "resourceType": "AllergyIntolerance",
        "clinicalStatus": {"coding": [{"system": "http://terminology.hl7.org/CodeSystem/allergyintolerance-clinical", "code": "active"}]},
        "type": "allergy",
        "category": ["food"],
        "criticality": "high",
        "code": {"coding": [{"system": "http://snomed.info/sct", "code": "91935009", "display": "Allergy to peanuts"}]},
        "patient": {"reference": f"Patient/{patient_id}"}
    }

def generate_medication_statement(patient_id):
    return {
        "resourceType": "MedicationStatement",
        "status": "active",
        "medicationCodeableConcept": {"coding": [{"system": "http://www.nlm.nih.gov/research/umls/rxnorm", "code": "860975", "display": "Metformin 500 MG Oral Tablet"}]},
        "subject": {"reference": f"Patient/{patient_id}"},
        "effectiveDateTime": datetime.now().isoformat()
    }

def main():
    for i in range(1, NUM_PATIENTS + 1):
        print(f"Seeding patient {i}/{NUM_PATIENTS}")
        patient = generate_patient(i)
        patient_id = post_resource("Patient", patient)
        if not patient_id:
            continue

        # Add standalone records
        post_resource("AllergyIntolerance", generate_allergy(patient_id))
        post_resource("MedicationStatement", generate_medication_statement(patient_id))

        for _ in range(ENCOUNTERS_PER_PATIENT):
            encounter = generate_encounter(patient_id)
            encounter_id = post_resource("Encounter", encounter)
            if not encounter_id:
                continue

            # Related resources
            post_resource("Condition", generate_condition(patient_id, encounter_id))
            post_resource("Procedure", generate_procedure(patient_id, encounter_id))

            for _ in range(OBSERVATIONS_PER_ENCOUNTER):
                post_resource("Observation", generate_observation(patient_id, encounter_id))

if __name__ == "__main__":
    main()
