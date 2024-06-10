public class SaltoExternalIdService {
    private static final String SALTO_ID_FIELD_API_NAME = 'SaltoId__c';
    private static final String SALTO_ID_FIELD_LABEL = 'Salto ID';
    private static final Double API_VERSION = 60.0;

    private static MetadataService.MetadataPort createService() { 
		MetadataService.MetadataPort service = new MetadataService.MetadataPort();
		service.SessionHeader = new MetadataService.SessionHeader_element();
		service.SessionHeader.sessionId = UserInfo.getSessionId();
		return service;		
	}

    private static Set<String> getObjectsWithSaltoIdField () {
        MetadataService.MetadataPort service = createService();
        List<MetadataService.ListMetadataQuery> queries = new List<MetadataService.ListMetadataQuery>();		
		MetadataService.ListMetadataQuery customFieldQuery = new MetadataService.ListMetadataQuery();
		customFieldQuery.type_x = 'CustomField';
		queries.add(customFieldQuery);
        Set<String> customFieldsFullNames = new Set<String>();
        MetadataService.FileProperties[] fileProperties = service.listMetadata(queries, 25);
        Set<String> objectsWithSaltoIdField = new Set<String>();
        for(MetadataService.FileProperties fileProperty : fileProperties) {
            String[] nameParts = fileProperty.fullName.split('\\.');
            if (nameParts.size() == 2 && nameParts[1].equals(SALTO_ID_FIELD_API_NAME)) {
                objectsWithSaltoIdField.add(nameParts[0]);
            }
        }
        return objectsWithSaltoIdField;
    }

    private static MetadataService.CustomField getField(String objectName) {
        MetadataService.CustomField field = new MetadataService.CustomField();
        field.fullName = objectName + '.' + SALTO_ID_FIELD_API_NAME;
        // field.businessStatus = 'Active';
        field.label = SALTO_ID_FIELD_LABEL;
        field.unique = true;
        field.type_x = 'Text';
        field.length = 18;
        return field;
    }

    private static MetadataService.Profile getFLSProfile(String profileName, Set<string> objectsToHandle) {
        MetadataService.Profile profile = new MetadataService.Profile();
        profile.fullName = profileName;
        profile.fieldPermissions = new List<MetadataService.ProfileFieldLevelSecurity>();
        profile.objectPermissions = new List<MetadataService.ProfileObjectPermissions>();
        for(String objectName : objectsToHandle) {
            MetadataService.ProfileFieldLevelSecurity fieldPermission = new MetadataService.ProfileFieldLevelSecurity();
            fieldPermission.field = objectName + '.' + SALTO_ID_FIELD_API_NAME;
            fieldPermission.editable = true;
            fieldPermission.readable = true;
            profile.fieldPermissions.add(fieldPermission);
        }
        return profile;
    }

    private static void handleSaveResults(String action, String typeName, List<MetadataService.SaveResult> saveResults) {
        for (MetadataService.SaveResult saveResult : saveResults) {
            if (saveResult.success) {
                System.debug(typeName + ' ' + action + ' successfully: ' + saveResult.fullName);
            } else {
                for (MetadataService.Error error : saveResult.errors) {
                    System.debug('Error on ' + typeName + ' ' + saveResult.fullName + ': ' + error.message);
                }
            }
        }
    }

    public static void addSaltoIdField(Set<String> objectNames, Set<String> flsProfiles) {
        Set<String> objectsToHandle = new Set<String>(objectNames);
        objectsToHandle.removeAll(getObjectsWithSaltoIdField());
        if (objectsToHandle.isEmpty()) {
            System.debug('No objects to handle');
            return;
        }
        MetadataService.MetadataPort service = createService();
        System.debug('Adding Salto ID Field to the following Objects: ' + objectsToHandle);


        MetadataService.Metadata[] fields = new MetadataService.Metadata[]{};
        MetadataService.Metadata[] profiles = new MetadataService.Metadata[]{};
        // Create CustomField and ApexTrigger changes
        for (String objectName: objectsToHandle) {
            fields.add(getField(objectName));
        }
        // Create FLS Profiles changes
        for (String flsProfile: flsProfiles) {
            profiles.add(getFLSProfile(flsProfile, objectsToHandle));
        }

        // Create Fields
        List<MetadataService.SaveResult> fieldResults = service.createMetadata(fields);
        handleSaveResults('created', 'Field', fieldResults);
        // Make fields visible in FLS Profiles
        List<MetadataService.SaveResult> profileResults = service.updateMetadata(profiles);
        handleSaveResults('modified', 'Profile', profileResults);
    }

    private static Set<String> getAllTriggerNames() {
        MetadataService.MetadataPort service = createService();
        List<MetadataService.ListMetadataQuery> queries = new List<MetadataService.ListMetadataQuery>();		
		MetadataService.ListMetadataQuery apexTriggerQuery = new MetadataService.ListMetadataQuery();
		apexTriggerQuery.type_x = 'ApexTrigger';
		queries.add(apexTriggerQuery);
        Set<String> customFieldsFullNames = new Set<String>();
        MetadataService.FileProperties[] fileProperties = service.listMetadata(queries, 25);
        Set<String> triggerNames = new Set<String>();
        for(MetadataService.FileProperties fileProperty : fileProperties) {
            triggerNames.add(fileProperty.fullName);
        }
        return triggerNames;
    }

    private static String triggerNameFromObject (String objectName) {
        String triggerNamePrefix = objectName;
        if (triggerNamePrefix.endsWith('__c')) {
            triggerNamePrefix = triggerNamePrefix.replaceAll('__c', '');
        }
        triggerNamePrefix = triggerNamePrefix.replaceAll('_', '');
        return triggerNamePrefix + 'SaltoId' + 'Trigger';
    }

    private class ApexTrigger {
        public String fullName;
        public Double apiVersion;
        public String status;
        public String parentObject;
        public String content;
    }

    private static ApexTrigger getTrigger(String objectName) {
        String triggerName = triggerNameFromObject(objectName);
        ApexTrigger metadataTrigger = new ApexTrigger();
        metadataTrigger.fullName = triggerName;
        metadataTrigger.parentObject = objectName;
        metadataTrigger.apiVersion = API_VERSION;
        metadataTrigger.status = 'Active';
        metadataTrigger.content = 'trigger ' + triggerName + ' on ' + objectName + ' (after insert) {\n';
        metadataTrigger.content += '    SaltoInternalId.updateSaltoId(Trigger.new);\n';
        metadataTrigger.content += '}';
        return metadataTrigger;
    }

    public static void createTrigger(ApexTrigger apexTrigger) {
        String toolingApiEndpoint = System.Url.getOrgDomainUrl().toExternalForm() + '/services/data/v' + API_VERSION + '/tooling/sobjects/ApexTrigger';
        System.debug('Tooling API endpoint: ' + toolingApiEndpoint);
        
        HttpRequest req = new HttpRequest();
        req.setEndpoint(toolingApiEndpoint);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');

        // Prepare the JSON body for the request
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('Name', apexTrigger.fullName);
        payload.put('TableEnumOrId', apexTrigger.parentObject);
        payload.put('Body', apexTrigger.content);
        req.setBody(JSON.serialize(payload));

        Http http = new Http();
        try {
            HttpResponse res = http.send(req);
            if (res.getStatusCode() == 201) {
                System.debug('Trigger deployed successfully');
            } else {
                System.debug('Failed to deploy trigger: ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug('Exception: ' + e.getMessage());
        }
    }

    public static void addSaltoIdFieldTriggers() {
        Set<String> objectsWithSaltoIdField = getObjectsWithSaltoIdField();
        if (objectsWithSaltoIdField.isEmpty()) {
            System.debug('No objects with Salto ID field');
            return;
        }
        ApexTrigger[] triggers = new ApexTrigger[]{};
        for (String objectName: objectsWithSaltoIdField) {
            triggers.add(getTrigger(objectName));
        }
        Set<String> existingTriggersNames = getAllTriggerNames();
        ApexTrigger[] triggersToAdd = new ApexTrigger[]{};
        for (ApexTrigger apexTrigger: triggers) {
            if (existingTriggersNames.contains(apexTrigger.fullName)) {
                System.debug('Trigger ' + apexTrigger.fullName + ' already exists');
            } else {
                triggersToAdd.add(apexTrigger);
            }
        }
        if (triggersToAdd.isEmpty()) {
            System.debug('No triggers to add');
            return;
        }
        for (ApexTrigger apexTrigger: triggersToAdd) {
            createTrigger(apexTrigger);
        }
    }

    public static void updateSaltoId(List<SObject> records) {
        // List to hold the SObjects to be updated
        List<SObject> recordsToUpdate = new List<SObject>();
        
        // Iterate over the new records
        for (SObject record : records) {
            // Get the Id of the record
            Id recordId = (Id)record.get('Id');
            // Get the current value of the specified field
            Id currentFieldValue = (Id)record.get(SALTO_ID_FIELD_API_NAME);
            
            // Check if the field is not already set
            if (currentFieldValue == null) {
                // Create a new SObject instance and set the Id and the field
                SObject updatedRecord = record.clone(false, true, false, false);
                updatedRecord.put('Id', recordId);
                updatedRecord.put(SALTO_ID_FIELD_API_NAME, recordId);
                recordsToUpdate.add(updatedRecord);
            }
        }
        
        // Perform the update outside the loop
        if (!recordsToUpdate.isEmpty()) {
            update recordsToUpdate;
        }
    }
}