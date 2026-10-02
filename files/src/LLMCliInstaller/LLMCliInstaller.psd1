@{
    RootModule = 'LLMCliInstaller.psm1'
    ModuleVersion = '3.0.0'
    GUID = 'f802424d-c932-4f40-92a7-6982cc12fe91'
    Author = 'LLM CLI Installer contributors'
    CompanyName = 'Community'
    Copyright = '(c) 2026'
    Description = 'Windows 11 x64용 공식 LLM CLI 진단, 설치, 정본 이전 및 검증 모듈'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-LlmCliInstaller', 'New-LlmCliSupportBundle')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Tags = @('Windows', 'CLI', 'Installer') } }
}
