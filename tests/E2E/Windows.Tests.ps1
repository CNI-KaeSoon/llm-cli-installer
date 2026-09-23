$module = Join-Path $PSScriptRoot '../../src/LLMCliInstaller/LLMCliInstaller.psd1'

Describe 'Windows release smoke gate' -Tag WindowsE2E {
    It 'imports and performs a no-change run on Windows' -Skip:($env:OS -ne 'Windows_NT') {
        Import-Module $module -Force
        (Invoke-LlmCliInstaller -Components antigravity -NonInteractive -WhatIf -NoSupportBundle).RunId | Should -Not -BeNullOrEmpty
    }
    It 'previews real inventory with keep default and no changes' -Skip:($env:OS -ne 'Windows_NT') {
        Import-Module $module -Force
        $result = Invoke-LlmCliInstaller -Components all -NonInteractive -WhatIf -NoSupportBundle
        $result.ExitCode | Should -Be 0
        @($result.MigrationPreview | Where-Object { $_.decision -eq 'Migrate' }).Count | Should -Be 0
    }
}
