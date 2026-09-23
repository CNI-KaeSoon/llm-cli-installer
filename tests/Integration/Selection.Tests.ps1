$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'
Import-Module $module -Force

Describe 'Safe dry-run orchestration' -Tag Integration {
    It 'all never plans Legacy Gemini' {
        $result = Invoke-LlmCliInstaller -Components all -NonInteractive -WhatIf -LogRoot (Join-Path $TestDrive 'logs') -NoSupportBundle
        @($result.Components.Id) | Should -Contain 'antigravity'
        @($result.Components.Id) | Should -Not -Contain 'legacy-gemini'
    }
    It 'google alias plans Antigravity without Node' {
        $result = Invoke-LlmCliInstaller -Components google -NonInteractive -WhatIf -LogRoot (Join-Path $TestDrive 'logs') -NoSupportBundle
        @($result.SelectedComponents) | Should -Be @('antigravity')
        @($result.Components | Where-Object Id -eq 'node').Count | Should -Be 0
    }
}
