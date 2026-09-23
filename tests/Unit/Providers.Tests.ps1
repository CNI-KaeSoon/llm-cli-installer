$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'
Import-Module $module -Force

Describe 'Provider contracts' -Tag Unit {
    InModuleScope LLMCliInstaller {
        It 'catalog contains only HTTPS official sources' {
            foreach ($item in (Get-ComponentCatalog).Values) {
                foreach ($uri in @($item.OfficialUris)) { ([uri]$uri).Scheme | Should -Be 'https' }
            }
        }
        It 'Antigravity has no Node dependency' {
            @((Get-ComponentCatalog).antigravity.DependsOn).Count | Should -Be 0
        }
        It 'Grok and Legacy Gemini depend on Node' {
            (Get-ComponentCatalog).grok.DependsOn | Should -Contain 'node'
            (Get-ComponentCatalog).'legacy-gemini'.DependsOn | Should -Contain 'node'
        }
        It 'Python manager list must contain one 3.14 runtime' {
            Test-PythonManagerList -Text '* 3.14.2' | Should -BeTrue
            Test-PythonManagerList -Text '3.13.9' | Should -BeFalse
            Test-PythonManagerList -Text "3.14.1`n3.14.2" | Should -BeFalse
        }
        It 'known Claude doctor guidance is warning only on exit zero' {
            (Get-ClaudeDoctorClassification -ExitCode 0 -Output 'Authentication required').Status | Should -Be 'VerifiedWithWarning'
            (Get-ClaudeDoctorClassification -ExitCode 1 -Output 'Authentication required').Code | Should -Be 50
            (Get-ClaudeDoctorClassification -ExitCode 0 -Output 'Git Bash missing').Code | Should -Be 50
        }
    }
}
