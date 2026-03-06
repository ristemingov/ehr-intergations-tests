import type { BotEvent, MedplumClient } from '@medplum/core';
import type { AllergyIntolerance, Bundle, BundleEntry, Condition, Encounter, MedicationStatement, Observation, Patient, Procedure, Resource } from '@medplum/fhirtypes';

const EHR_BASE = 'http://ehr:8080'; // Docker internal hostname

export async function handler(medplum: MedplumClient, _event: BotEvent): Promise<void> {
  console.log('Starting EHR import...');

  const bundle = await fetchFhir<Bundle>(`${EHR_BASE}/Patient?_count=200`);
  const entries = bundle.entry ?? [];
  console.log(`Found ${entries.length} patients in EHR`);

  for (const entry of entries) {
    const ehrPatient = entry.resource as Patient;
    if (!ehrPatient?.id) continue;

    // Upsert patient - use EHR id as an identifier so re-runs are idempotent
    const identifier = `ehr://hospital|${ehrPatient.id}`;
    const patient = await medplum.upsertResource(
      {
        ...ehrPatient,
        id: undefined, // let Medplum assign its own id
        identifier: [{ system: 'ehr://hospital', value: ehrPatient.id }],
      },
      `identifier=${identifier}`
    );
    console.log(`Upserted Patient ${patient.id} (EHR id: ${ehrPatient.id})`);

    // Import related resources in parallel
    await Promise.all([
      importResources<Encounter>(medplum, ehrPatient.id, patient.id as string, 'Encounter', 'subject'),
      importResources<Observation>(medplum, ehrPatient.id, patient.id as string, 'Observation', 'subject'),
      importResources<Condition>(medplum, ehrPatient.id, patient.id as string, 'Condition', 'subject'),
      importResources<Procedure>(medplum, ehrPatient.id, patient.id as string, 'Procedure', 'subject'),
      importResources<AllergyIntolerance>(medplum, ehrPatient.id, patient.id as string, 'AllergyIntolerance', 'patient'),
      importResources<MedicationStatement>(medplum, ehrPatient.id, patient.id as string, 'MedicationStatement', 'subject'),
    ]);
  }

  console.log('EHR import complete.');
}

async function importResources<T extends Resource>(
  medplum: MedplumClient,
  ehrPatientId: string,
  medplumPatientId: string,
  resourceType: T['resourceType'],
  patientParam: string
): Promise<void> {
  const bundle = await fetchFhir<Bundle>(`${EHR_BASE}/${resourceType}?${patientParam}=Patient/${ehrPatientId}&_count=100`);
  for (const entry of (bundle.entry ?? []) as BundleEntry<T>[]) {
    const resource = entry.resource;
    if (!resource?.id) continue;
    try {
      await medplum.createResourceIfNoneExist(
        {
          ...resource,
          id: undefined,
          // Re-point the patient reference to the Medplum patient
          ...(patientParam === 'subject' ? { subject: { reference: `Patient/${medplumPatientId}` } } : {}),
          ...(patientParam === 'patient' ? { patient: { reference: `Patient/${medplumPatientId}` } } : {}),
          identifier: [{ system: 'ehr://hospital', value: resource.id }],
        } as T,
        `identifier=ehr://hospital|${resource.id}`
      );
    } catch (err) {
      console.error(`Failed to import ${resourceType} ${resource.id}: ${err}`);
    }
  }
}

async function fetchFhir<T>(url: string): Promise<T> {
  const res = await fetch(url, { headers: { Accept: 'application/fhir+json' } });
  if (!res.ok) throw new Error(`FHIR fetch failed: ${res.status} ${url}`);
  return res.json() as Promise<T>;
}
