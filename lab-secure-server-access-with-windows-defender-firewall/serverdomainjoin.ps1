# Join computer corp.awesome.com domain and add it to the "servermembers" OU

$pw = 'p@55w0rd'
$ou = 'OU=servermembers'

$joinCred = New-Object pscredential -ArgumentList ([pscustomobject]@{
    UserName = "CORP\awesomeadmin"
    Password = (ConvertTo-SecureString -String $pw -AsPlainText -Force)[0]
})
Add-Computer -DomainName "corp.awesome.com" -OUPath "$ou,DC=corp,DC=awesome,DC=com" -Credential $joinCred 

