@{
    Severity = @('Error', 'Warning')
    IncludeRules = @('*')
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
        PSAvoidUsingInvokeExpression = @{ Enable = $true }
    }
}
