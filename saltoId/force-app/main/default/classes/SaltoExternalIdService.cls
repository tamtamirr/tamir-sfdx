public class SaltoExternalIdService {
    private static final String SALTO_ID_FIELD_API_NAME = 'SaltoId__c';
    private static final String SALTO_ID_FIELD_DEVELOPER_NAME = SALTO_ID_FIELD_API_NAME.replaceAll('__c', '');
    private static final String SALTO_ID_FIELD_LABEL = 'Salto ID';
    private static final Double API_VERSION = 60.0;

    private static final String TRIGGER_SUFFIX = 'SaltoIdTrigger';

    private static MetadataService.MetadataPort createService() { 
		MetadataService.MetadataPort service = new MetadataService.MetadataPort();
		service.SessionHeader = new MetadataService.SessionHeader_element();
		service.SessionHeader.sessionId = UserInfo.getSessionId();
		return service;		
	}

    public static Set<String> getObjectsWithSaltoIdField () {
        ToolingAPI toolingAPI = new ToolingAPI();
        ToolingAPIWSDL.sObject_x[] customFields = toolingAPI.queryAll('SELECT TableEnumOrId FROM CustomField Where DeveloperName = \''+ SALTO_ID_FIELD_DEVELOPER_NAME + '\'').records;
        Set<String> objectsWithSaltoIdField = new Set<String>();
        for (ToolingAPIWSDL.sObject_x field : customFields) {
            objectsWithSaltoIdField.add(field.TableEnumOrId);
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

    public static void createSaltoIdField(Set<String> objectNames, Set<String> flsProfiles) {
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
        // Create CustomField changes
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

    public static Set<String> getObjectsWithExistingTrigger() {
        String query = 'SELECT TableEnumOrId FROM ApexTrigger WHERE Name Like \'%' + TRIGGER_SUFFIX  + '\'';
        List<ApexTrigger> apexTriggers = Database.query(query);
        Set<String> triggerNames = new Set<String>();
        for(ApexTrigger apexTrigger: apexTriggers) {
            triggerNames.add(apexTrigger.TableEnumOrId);
        }
        return triggerNames;
    }

    private static String triggerNameFromObject (String objectName) {
        String triggerNamePrefix = objectName;
        if (triggerNamePrefix.endsWith('__c')) {
            triggerNamePrefix = triggerNamePrefix.replaceAll('__c', '');
        }
        triggerNamePrefix = triggerNamePrefix.replaceAll('_', '');
        return triggerNamePrefix + TRIGGER_SUFFIX;
    }

    private class ApexTriggerMetadata {
        public String fullName;
        public Double apiVersion;
        public String status;
        public String parentObject;
        public String content;
    }

    private static ApexTriggerMetadata getTrigger(String objectName) {
        String triggerName = triggerNameFromObject(objectName);
        ApexTriggerMetadata metadataTrigger = new ApexTriggerMetadata();
        metadataTrigger.fullName = triggerName;
        metadataTrigger.parentObject = objectName;
        metadataTrigger.apiVersion = API_VERSION;
        metadataTrigger.status = 'Active';
        metadataTrigger.content = 'trigger ' + triggerName + ' on ' + objectName + ' (after insert) {\n';
        metadataTrigger.content += '    SaltoExternalIdService.updateSaltoId(Trigger.new);\n';
        metadataTrigger.content += '}';
        return metadataTrigger;
    }

    public static void createTrigger(ApexTriggerMetadata apexTrigger) {
        String toolingApiEndpoint = System.Url.getOrgDomainUrl().toExternalForm() + '/services/data/v' + API_VERSION + '/tooling/sobjects/ApexTrigger';
        
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
        payload.put('Status', apexTrigger.status);
        payload.put('ApiVersion', apexTrigger.apiVersion);
        req.setBody(JSON.serialize(payload));

        Http http = new Http();
        try {
            HttpResponse res = http.send(req);
            if (res.getStatusCode() == 201) {
                System.debug('Trigger ' + apexTrigger.fullName +  ' created successfully');
            } else {
                System.debug('Failed to deploy trigger ' + apexTrigger.fullName + ': ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug('Exception occurred when attempting to create trigger' + apexTrigger.fullName + ': ' + e.getMessage());
        }
    }

    public static void createSaltoIdFieldTriggers() {
        Set<String> objectsWithSaltoIdField = getObjectsWithSaltoIdField();
        ApexTriggerMetadata[] triggers = new ApexTriggerMetadata[]{};
        Set<String> objectsWithExistingTrigger = getObjectsWithExistingTrigger();
        for (String objectName: objectsWithSaltoIdField) {
            if (!objectsWithExistingTrigger.contains(objectName)) {
                triggers.add(getTrigger(objectName));
            }
        }
        if (triggers.isEmpty()) {
            System.debug('No triggers to add');
            return;
        }
        for (ApexTriggerMetadata apexTrigger: triggers) {
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

    public static void updateExistingRecordsSaltoIdField() {
        for (String objectName: getObjectsWithSaltoIdField()) {
            List<SObject> records = Database.query('SELECT Id, ' + SALTO_ID_FIELD_API_NAME + ' FROM ' + objectName + ' WHERE ' + SALTO_ID_FIELD_API_NAME + ' = null');
            updateSaltoId(records);
        }
    }
}