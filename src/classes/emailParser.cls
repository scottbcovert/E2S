/*
 * An apex email service that allows the user
 * to capture the contents of inbound emails 
 * to create corresponding Salesforce records
 *
 * Scott Covert
 * Director of Product Development - edjix
 * 4/18/13
 */
 
global class emailParser implements Messaging.InboundEmailHandler {

    global Messaging.InboundEmailResult handleInboundEmail(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailresult();

        //Capture email body
        String emailBody = email.plainTextBody;
        if (emailBody==null || emailBody ==''){
            emailBody = email.htmlBody;
        }
        
        //Strip any HTML from email body
        
        //Replace all <br/> (case-insensitive) tags with \n to support new lines
        emailBody = emailBody.replaceAll('(?i)<br/>', '\n');
        emailBody = emailBody.replaceAll('(?i)<br />', '\n');
        
        //Regular expression to match all HTML tags
        String HTML_TAG_PATTERN = '<.*?>';

        //Compile the pattern     
        Pattern myPattern = pattern.compile(HTML_TAG_PATTERN);

        //Define matcher instance
        Matcher myMatcher = myPattern.matcher(emailBody);

        //Strip HTML     
        emailBody = myMatcher.replaceAll('');               
        
        //Search for custom setting that matches sender address    
        Object_Rules__c relevantRule;
        Boolean useFallback = false;
        Boolean ignoreUnknownSources = false;
        List<Object_Rules__c> objectRules = Object_Rules__c.getall().values();
        String fromAddress = '';
        if (email.headers!=null){
            for (Messaging.InboundEmail.Header header : email.headers) {
              if (header.name=='From'){
                  fromAddress = header.value.substringBetween('<','>');
                  break;
              }  
            }
        }    
        if (fromAddress == ''){
            fromAddress = envelope.fromAddress;
        }
        for (Object_Rules__c rule : objectRules){
            if (rule.Sender_Email_Address__c.equalsIgnoreCase(fromAddress)){
                relevantRule = rule;
                break;
            }
        }    
        
        //If no custom setting matches the sender address then use the default rule
        if (relevantRule==null){
            for (Object_Rules__c rule : objectRules){
                if (rule.Default_Rule__c){
                    relevantRule = rule;
                    break;
                }
            }
        }
        
        //If no default rule has been defined then use fallback settings
        if (relevantRule==null){
            useFallback = true;
        }
        
        //Determine if unknown sources should be ignored
        General_Settings__c genSettingsRule = General_Settings__c.getInstance();
        if (genSettingsRule!=null){
            if (genSettingsRule.Ignore_Unknown_Sources__c!=null){
                ignoreUnknownSources = genSettingsRule.Ignore_Unknown_Sources__c;
            }
        }
        
        if (useFallback){
          if (!ignoreUnknownSources){
            try{
            
                //Fallback - Create lead with basic information from email
                Lead l = new Lead();
                
                //Lead name
                String fromName = email.FromName;
                String fName = '';
                String lName = '';
                if (fromName!=null){
                    if (fromName.contains(' ')){
                        fName = fromName.split('[ ]')[0];
                        lName = fromName.split('[ ]')[1]; 
                    }
                    else{
                        lName = fromName;
                    }
                }
                l.FirstName = fName;
                l.LastName = lName;
                
                //Lead email
                l.Email = fromAddress;
                
                //Lead company
                String company = 'Unknown';
                if (fromAddress!=null && fromAddress.contains('@')){
                    company = fromAddress.split('@')[1];
                    if (company.contains('.')){
                        company = company.split('[.]')[0];
                    }
                }
                l.Company = company;
                
                //Lead description
                l.Description = email.Subject;
                
                //Lead source
                l.LeadSource = fromAddress;
                
                //Insert lead
                insert l; 
                
                //Create attachment of email body
                Attachment a = new Attachment();
                a.Name = email.Subject;
                a.Body = Blob.valueOf(emailBody);
                a.ParentId = l.Id;
                insert a;
            }
            
            catch(System.Exception e){
                //Error             
            }
          }  
        }
        
        else{
            try{
                //Search for decoder overrides
                List<Decoder_Overrides__c> decoderOverrides = Decoder_Overrides__c.getall().values();
                for (Decoder_Overrides__c decOverride : decoderOverrides ){                 
                    if (decOverride.Corresponding_E2S_Rule__c == relevantRule.Name){
                        //Strip unwanted character from decoded email
                        String unwantedCharacter = decOverride.Unwanted_Character__c;
                        String subCharacter = decOverride.Substitute_Character__c;
                        if (subCharacter!=null && subCharacter!=''){
                            emailBody = emailBody.replace(unwantedCharacter,subCharacter);
                        }
                        else{
                            emailBody = emailBody.replace(unwantedCharacter,'');
                        }
                    }   
                }
                
                //Add line break to EOF
                emailBody = emailBody + '[EOF]' + '\n';
            
                //Find all field mappings that correspond to the relevant object rule
                List<Field_Mappings__c> relevantFieldMappings = new List<Field_Mappings__c>();
                List<Field_Mappings__c> fieldMappings = Field_Mappings__c.getall().values();
                for (Field_Mappings__c fMapping : fieldMappings){
                    if (fMapping.Corresponding_E2S_Rule__c == relevantRule.Name){
                        relevantFieldMappings.add(fMapping);
                    }
                }
                
                //Define new record         
                Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
                Schema.SObjectType oType = gd.get(relevantRule.Object_API_Name__c);
                map<String, Schema.SObjectField> mapFieldList = oType.getDescribe().fields.getMap();
                Schema.DisplayType fieldType;
                SObject newRecord = oType.newSObject();
                list<Attachment> aList = new list<Attachment>();            
                
                //Iterate through field mappings and map data to Salesforce record
                for (Field_Mappings__c rfm : relevantFieldMappings){                    
                    String dataValue = '';
                    if (rfm.Use_Line_Break_for_Closing_Tag__c){
                        dataValue = emailBody.substringBetween(rfm.Opening_Tag__c,'\n');                        
                    }                   
                    else{
                        dataValue = emailBody.substringBetween(rfm.Opening_Tag__c,rfm.Closing_Tag__c); 
                    }
                    //Add special case for mapping email subject
                    if (rfm.Opening_Tag__c.toLowercase()=='email subject:'){
                        dataValue = email.Subject;
                    }                   
                    if (rfm.Salesforce_Field__c.contains(';')){
                        list<String> apiNames = rfm.Salesforce_Field__c.split(';');
                        if (dataValue.trim().contains(' ')){
                            //Space delimited data being stored in multiple fields                          
                            list<String> dataValues = dataValue.trim().split('[ ]');                        
                            
                            //Avoid array out of bounds condition
                            Integer max = dataValues.size();
                            if (max>apiNames.size()){
                                max = apiNames.size();
                            }
                            for (Integer i=0; i < max; i++){
                                //Remove non-numeric characters with RegEx for number fields
                                fieldType = mapFieldList.get(apiNames[i]).getDescribe().getType();
                                if (fieldType==Schema.DisplayType.Integer) {
                                    dataValues[i] = dataValues[i].replaceAll('[^\\d-]','');
                                }
                                else if (fieldType==Schema.DisplayType.Double || fieldType==Schema.DisplayType.Currency) {
                                    dataValues[i] = dataValues[i].replaceAll('[^\\d.-]','');
                                }
                                //Store data in corresponding field
                                newRecord.put(apiNames[i],dataValues[i]);
                            }       
                        }               
                        else{
                            //No spaces found-copying data value to all fields
                            for (String fieldName : apiNames){
                                //Remove non-numeric characters with RegEx for number fields
                                fieldType = mapFieldList.get(fieldName).getDescribe().getType();
                                if (fieldType==Schema.DisplayType.Integer) {
                                    dataValue = dataValue.replaceAll('[^\\d-]','');
                                }
                                else if (fieldType==Schema.DisplayType.Double || fieldType==Schema.DisplayType.Currency) {
                                    dataValue = dataValue.replaceAll('[^\\d.-]','');
                                }
                                //Store data in corresponding field
                                newRecord.put(fieldName,dataValue);
                            }
                        }
                    }                   
                    else{
                        //Remove non-numeric characters with RegEx for number fields
                        fieldType = mapFieldList.get(rfm.Salesforce_Field__c).getDescribe().getType();
                        if (fieldType==Schema.DisplayType.Integer) {
                            dataValue = dataValue.replaceAll('[^\\d-]','');
                        }
                        else if (fieldType==Schema.DisplayType.Double || fieldType==Schema.DisplayType.Currency) {
                            dataValue = dataValue.replaceAll('[^\\d.-]','');
                        }
                        //Store data in corresponding field
                        newRecord.put(rfm.Salesforce_Field__c,dataValue);
                    }
                    if (rfm.Create_Attachment__c){
                        //Create attachment of data value                       
                        Attachment dataAttachment = new Attachment();
                        dataAttachment.Name = rfm.Opening_Tag__c;
                        dataAttachment.Body = Blob.valueOf(rfm.Opening_Tag__c + dataValue);
                        dataAttachment.ContentType = 'text/plain';                      
                        aList.add(dataAttachment);                      
                    }
                }
                
                //Verify Source is defined if applicable
                if (relevantRule.Object_Source_Field_API_Name__c!=null){
                    if (newRecord.get(relevantRule.Object_Source_Field_API_Name__c)==null || newRecord.get(relevantRule.Object_Source_Field_API_Name__c)==''){
                        //Source field is currently blank or null, populate with relevant E2S rule name
                        newRecord.put(relevantRule.Object_Source_Field_API_Name__c,relevantRule.Name);
                    }
                }
                else if (relevantRule.Object_API_Name__c=='Lead'){
                    //Automatically use LeadSource field if rule is set up for the Lead object
                    if (newRecord.get('LeadSource')==null || newRecord.get('LeadSource')==''){
                        //LeadSource is currently blank or null, populate with relevant E2S rule name
                        newRecord.put('LeadSource',relevantRule.Name);
                    }
                }
                
                //Insert new record
                insert newRecord;
                
                //Try to create attachments of email body and data values
                try{
                    Attachment a = new Attachment();
                    a.Name = email.Subject;
                    a.Body = Blob.valueOf(emailBody);
                    a.ContentType = 'text/plain';
                    a.ParentId = newRecord.Id;
                    insert a;
                    if (!aList.isEmpty()){
                        for (Attachment theAttachment : aList){
                            theAttachment.ParentId = newRecord.Id;
                        }
                        insert aList;
                    }
                }
                
                catch(System.Exception e){
                    //Error creating attachment(s)
                }                   
                
                //Query database for record data
                String queryString = 'SELECT Id, OwnerId';
                if (relevantRule.Notify_3rd_Party__c && relevantRule.X3rd_Party_Email_Field__c!=null && relevantRule.X3rd_Party_Email_Field__c!=''){
                    queryString = queryString + ', ' + relevantRule.X3rd_Party_Email_Field__c;
                }   
                queryString = queryString +' FROM ' + relevantRule.Object_API_Name__c + ' WHERE Id = \'' + newRecord.Id + '\' LIMIT 1';
                list<SObject> newSObject = Database.query(queryString);
                
                //Notify record owner
                if (relevantRule.Notify_Record_Owner__c){
                                                
                    //Obtain record owner's email address
                    String ownerEmailAddress;
                    if (!newSObject.isEmpty()){
                        if (String.valueOf(newSObject[0].get('OwnerId')).substring(0,3)=='005'){ 
                            User u = [SELECT Id, Email FROM User WHERE Id = :String.valueOf(newSObject[0].get('OwnerId')) LIMIT 1];
                            ownerEmailAddress = u.Email;
                            if (ownerEmailAddress!=null && ownerEmailAddress!=''){
                                //Define email settings
                                Messaging.SingleEmailMessage ownerMail = new Messaging.SingleEmailMessage();
                                ownerMail.setToAddresses(new String[] {ownerEmailAddress});
                                ownerMail.setSubject('E2S: New Record Created');
                                String newSObjectURL = URL.getSalesforceBaseUrl().toExternalForm() + '/' + String.valueOf(newSObject[0].get('Id'));
                                if (newSObjectURL.contains('http://')){
                                    newSObjectURL = newSObjectURL.replace('http://','');
                                }
                                if (newSObjectURL.contains('http//')){
                                    newSObjectURL = newSObjectURL.replace('http//','');
                                }
                                String textMessage = 'A new Salesforce record has been created by E2S for an email sent from ' + fromAddress + ' with subject of \'' + email.Subject + '\'; thanks for using E2S!';                            
                                String htmlMessage = 'A new Salesforce record has been created by E2S for an email sent from ' + fromAddress + ' with subject of \'' + email.Subject + '\'; please click here to <a href=\'https://' + newSObjectURL + '\'>view the record</a>-thanks for using E2S!';                         
                                ownerMail.setPlainTextBody(textMessage);
                                ownerMail.setHtmlBody(htmlMessage);
                                //Send email
                                Messaging.sendEmail(new Messaging.SingleEmailMessage[] {ownerMail});
                            }
                        }
                    }
                }
                
                //Notify 3rd party
                if (relevantRule.Notify_3rd_Party__c){
                    //Obtain 3rd party's email address                  
                    String thirdPartyEmailAddress;
                    if (relevantRule.X3rd_Party_Email_Field__c!=null && relevantRule.X3rd_Party_Email_Field__c!='' && !newSObject.isEmpty()){
                        thirdPartyEmailAddress = String.valueOf(newSObject[0].get(relevantRule.X3rd_Party_Email_Field__c));
                        if (thirdPartyEmailAddress!=null && thirdPartyEmailAddress!=''){
                            //Define email settings
                            Messaging.SingleEmailMessage thirdPartyMail = new Messaging.SingleEmailMessage();                   
                            thirdPartyMail.setToAddresses(thirdPartyEmailAddress.split(';'));
                            thirdPartyMail.setSubject('Your Information has been received by ' + UserInfo.getOrganizationName());
                            String emailMessage = 'This is a confirmation email from ' + UserInfo.getOrganizationName() + ' to alert you that your information has been received-thank you!';
                            thirdPartyMail.setPlainTextBody(emailMessage);
                            thirdPartyMail.setHtmlBody(emailMessage);
                            //Send email
                            Messaging.sendEmail(new Messaging.SingleEmailMessage[] {thirdPartyMail});
                        }
                    }
                }
                
                //Forward Original Email
                if (relevantRule.Forwarding_Email_Address__c!=null && relevantRule.Forwarding_Email_Address__c!=''){
                    //Define email settings
                    Messaging.SingleEmailMessage forwardEmail = new Messaging.SingleEmailMessage();
                    //Set Forwarding Address(es)
                    forwardEmail.setToAddresses(relevantRule.Forwarding_Email_Address__c.split(';'));
                    //Set Subject
                    forwardEmail.setSubject('FWD from E2S: ' + email.Subject);
                    /*//References
                    if (email.References!=null){
                        String refs = '';
                        Boolean firstIteration = true;
                        for (String s : email.References){
                            if (!firstIteration){
                                refs += ' ';
                            }
                            refs += s;
                            firstIteration = false;
                        }
                        if (refs!=''){
                            forwardEmail.setReferences(refs);
                        }
                    }
                    if (email.inReplyTo!=null && email.inReplyTo!=''){
                        forwardEmail.setInReplyTo(email.inReplyTo);
                    }*/
                    if (email.plainTextBody!=null && email.plainTextBody!=''){
                        forwardEmail.setPlainTextBody(email.plainTextBody);
                    }
                    if (email.htmlBody!=null && email.htmlBody!=''){
                        forwardEmail.setHtmlBody(email.htmlBody);
                    }
                    /*//Attachments
                    list<Messaging.EmailFileAttachment> attachmentList = new list<Messaging.EmailFileAttachment>();
                    for (Messaging.InboundEmail.BinaryAttachment b : email.binaryAttachments){
                        Messaging.EmailFileAttachment a;
                        a.setBody(b.Body);
                        a.setContentType(b.mimeTypeSubType);
                        a.setFileName(b.fileName);
                        a.setInline(false);
                        attachmentList.add(a);
                    }
                    for (Messaging.InboundEmail.TextAttachment t : email.textAttachments){
                        Messaging.EmailFileAttachment a;
                        a.setBody(Blob.valueOf(t.Body));
                        a.setContentType(t.mimeTypeSubType);
                        a.setFileName(t.fileName);
                        a.setInline(false);
                        attachmentList.add(a);
                    }
                    if (!attachmentList.isEmpty()){
                        forwardEmail.setFileAttachments(attachmentList);
                    }*/
                    //Forward email
                    Messaging.sendEmail(new Messaging.SingleEmailMessage[] {forwardEmail});                
                }                 
            }
            
            catch(System.Exception e){
                //Error: Notify default recipient               
                
                if (relevantRule.Error_Email_Address__c!=null && relevantRule.Error_Email_Address__c!=''){
                    //Define email settings
                    Messaging.SingleEmailMessage errorMail = new Messaging.SingleEmailMessage();
                    errorMail.setToAddresses(relevantRule.Error_Email_Address__c.split(';'));
                    errorMail.setSubject('E2S Error');
                    String errorMessage = 'Problem encountered by E2S for an email sent from ' + fromAddress + ' with subject of \'' + email.Subject + '\'; please verify settings for this source and try again.\n';
                    errorMessage += '***** Error Message: ' + e.getMessage() + ' *****\n';
                    errorMessage += '***** Line Number: ' + e.getLineNumber() + ' ****\n';
                    errorMessage += '***** Stack Trace: ' + e.getStackTraceString() + ' *****\n';
                    errorMail.setHtmlBody(errorMessage);
                    errorMail.setPlainTextBody(errorMessage);
                    //Send email
                    Messaging.sendEmail(new Messaging.SingleEmailMessage[] {errorMail});
                }
            }
        }

        return result;
    }
    
    static testMethod void testEmailParser() {
 
        //Create a new email and envelope object
        Messaging.InboundEmail email = new Messaging.InboundEmail() ;
        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
 
        //Setup the data for the email
        email.Subject = 'Test Lead';
        email.FromName = 'FirstName LastName';          
        email.plainTextBody = '';
        email.htmlBody = '*Name:* FirstName LastName *Company:* XYZ *Email:* someaddress@email.com\n';
        env.fromAddress = 'someaddress@email.com';
 
        //Call the emailParser class and test it
        emailParser emailParserTest = new emailParser();
        emailParserTest.handleInboundEmail(email, env);
 
        //Query for the attachment and lead the email service created
        Attachment a = [SELECT Id, Name FROM Attachment WHERE Name = :email.Subject LIMIT 1];
        Lead l = [SELECT Id, FirstName, LastName, Email, Company FROM Lead WHERE FirstName = 'FirstName' AND LastName = 'LastName' LIMIT 1];        
        
        //Verify the email service created the attachment and lead properly
        System.assertEquals(a.Name,email.Subject); 
        System.assertEquals(l.FirstName,'FirstName');
        System.assertEquals(l.LastName,'LastName');
        System.assertEquals(l.Company,'email');
        System.assertEquals(l.Email,'someaddress@email.com');               
        
        //Delete attachment and lead from database
        delete a;
        delete l;
        
        //Create Custom Settings
        Object_Rules__c leadRule = new Object_Rules__c(Name='Test',X3rd_Party_Email_Field__c='Email',Default_Rule__c=true,Error_Email_Address__c='someaddress@email.com',Notify_3rd_Party__c=true,Notify_Record_Owner__c=true,Object_API_Name__c='Lead',Sender_Email_Address__c='someotheraddress@email.com');
        insert leadRule;
        
        Field_Mappings__c leadNameMapping = new Field_Mappings__c(Name='NameMapping',Opening_Tag__c='Name: ',Salesforce_Field__c='FirstName;LastName',Corresponding_E2S_Rule__c='Test',Closing_Tag__c=' Company:',Use_Line_Break_for_Closing_Tag__c=false);
        insert leadNameMapping;
        
        Field_Mappings__c leadCompanyMapping = new Field_Mappings__c(Name='CompanyMapping',Opening_Tag__c='Company: ',Salesforce_Field__c='Company',Corresponding_E2S_Rule__c='Test',Closing_Tag__c=' Email:',Use_Line_Break_for_Closing_Tag__c=false,Create_Attachment__c=true);
        insert leadCompanyMapping;
        
        Field_Mappings__c leadEmailMapping = new Field_Mappings__c(Name='EmailMapping',Opening_Tag__c='Email: ',Salesforce_Field__c='Email',Corresponding_E2S_Rule__c='Test',Use_Line_Break_for_Closing_Tag__c=true);
        insert leadEmailMapping;
        
        Decoder_Overrides__c overrideRule = new Decoder_Overrides__c(Name='TestOverride',Corresponding_E2S_Rule__c='Test',Unwanted_Character__c='*');
        insert overrideRule;
        
        //Call the emailParser class again and test it now that the custom settings have been created
        emailParserTest.handleInboundEmail(email, env);
        
        //Query for the attachments and lead the email service created
        a = [SELECT Id, Name FROM Attachment WHERE Name = :email.Subject LIMIT 1];
        Attachment a2 = [SELECT Id, Name, Body FROM Attachment WHERE Name = 'Company:' LIMIT 1];
        l = [SELECT Id, FirstName, LastName, Email, Company FROM Lead WHERE FirstName = 'FirstName' AND LastName = 'LastName' LIMIT 1];         
        
        //Verify the email service created the attachments and lead properly
        System.assertEquals(a.Name,email.Subject); 
        System.assertEquals(a2.Body.toString(),'Company: XYZ ');
        System.assertEquals(l.FirstName,'FirstName');
        System.assertEquals(l.LastName,'LastName');
        System.assertEquals(l.Company,'XYZ');
        System.assertEquals(l.Email,'someaddress@email.com');       
        
        //Delete attachment and lead from database
        delete a;
        delete a2;
        delete l;
        
        //Change rule to have forwarding address
        leadRule.Forwarding_Email_Address__c = 'someaddress@email.com';
        
        //Change rule to match sender address
        leadRule.Sender_Email_Address__c = 'someaddress@email.com';
        update leadRule;
        
        //Call the emailParser class again and test it now that the rule's sender address has been updated
        emailParserTest.handleInboundEmail(email, env);
        
        //Query for the attachments and lead the email service created
        a = [SELECT Id, Name FROM Attachment WHERE Name = :email.Subject LIMIT 1];
        a2 = [SELECT Id, Name, Body FROM Attachment WHERE Name = 'Company:' LIMIT 1];
        l = [SELECT Id, FirstName, LastName, Email, Company FROM Lead WHERE FirstName = 'FirstName' AND LastName = 'LastName' LIMIT 1];         
        
        //Verify the email service created the attachment and lead properly
        System.assertEquals(a.Name,email.Subject);   
        System.assertEquals(a2.Body.toString(),'Company: XYZ ');
        System.assertEquals(l.FirstName,'FirstName');
        System.assertEquals(l.LastName,'LastName');
        System.assertEquals(l.Company,'XYZ');           
        System.assertEquals(l.Email,'someaddress@email.com');       
        
        //Force error to increase code coverage by removing mapping for a required field
        delete leadCompanyMapping;                  
        
        //Call the emailParser class again and test it now that an error will be forced to occur
        emailParserTest.handleInboundEmail(email, env);
    } 
}