[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Add", "Remove", "Enumerate")]
    [string]$Operation,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^S-\d(?:-\d+)+$')]
    [string]$Sid,

    [Parameter(Mandatory = $true)]
    [ValidateSet("SeIncreaseQuotaPrivilege")]
    [string]$Right
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$lsaSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class CmuxLsaAccountRight
{
    private const uint PolicyCreateAccount = 0x00000010;
    private const uint PolicyLookupNames = 0x00000800;
    private const uint StatusObjectNameNotFound = 0xC0000034;

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaObjectAttributes
    {
        public uint Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LsaUnicodeString
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [DllImport("advapi32.dll")]
    private static extern uint LsaOpenPolicy(
        IntPtr systemName,
        ref LsaObjectAttributes objectAttributes,
        uint desiredAccess,
        out IntPtr policyHandle);

    [DllImport("advapi32.dll")]
    private static extern uint LsaAddAccountRights(
        IntPtr policyHandle,
        IntPtr accountSid,
        LsaUnicodeString[] userRights,
        uint countOfRights);

    [DllImport("advapi32.dll")]
    private static extern uint LsaRemoveAccountRights(
        IntPtr policyHandle,
        IntPtr accountSid,
        byte allRights,
        LsaUnicodeString[] userRights,
        uint countOfRights);

    [DllImport("advapi32.dll")]
    private static extern uint LsaEnumerateAccountRights(
        IntPtr policyHandle,
        IntPtr accountSid,
        out IntPtr userRights,
        out uint countOfRights);

    [DllImport("advapi32.dll")]
    private static extern uint LsaFreeMemory(IntPtr buffer);

    [DllImport("advapi32.dll")]
    private static extern uint LsaClose(IntPtr policyHandle);

    [DllImport("advapi32.dll")]
    private static extern uint LsaNtStatusToWinError(uint status);

    public static void Apply(string sidValue, string rightValue, bool add)
    {
        if (String.IsNullOrEmpty(sidValue) || String.IsNullOrEmpty(rightValue))
            throw new ArgumentException("SID and account right are required");
        if (rightValue.Length > 32766)
            throw new ArgumentOutOfRangeException("rightValue");

        var attributes = new LsaObjectAttributes();
        attributes.Length = (uint)Marshal.SizeOf(typeof(LsaObjectAttributes));
        IntPtr policy;
        uint desiredAccess = PolicyLookupNames | (add ? PolicyCreateAccount : 0);
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, desiredAccess, out policy);
        ThrowIfFailed(status, "open local security policy");

        IntPtr rightBuffer = IntPtr.Zero;
        GCHandle sidHandle = default(GCHandle);
        try
        {
            var sid = new SecurityIdentifier(sidValue);
            var sidBytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(sidBytes, 0);
            sidHandle = GCHandle.Alloc(sidBytes, GCHandleType.Pinned);
            rightBuffer = Marshal.StringToHGlobalUni(rightValue);
            var right = new LsaUnicodeString {
                Length = checked((ushort)(rightValue.Length * 2)),
                MaximumLength = checked((ushort)((rightValue.Length + 1) * 2)),
                Buffer = rightBuffer
            };
            var rights = new[] { right };
            status = add
                ? LsaAddAccountRights(policy, sidHandle.AddrOfPinnedObject(), rights, 1)
                : LsaRemoveAccountRights(policy, sidHandle.AddrOfPinnedObject(), 0, rights, 1);
            ThrowIfFailed(status, add ? "grant account right" : "remove account right");
        }
        finally
        {
            if (sidHandle.IsAllocated) sidHandle.Free();
            if (rightBuffer != IntPtr.Zero) Marshal.FreeHGlobal(rightBuffer);
            LsaClose(policy);
        }
    }

    public static string[] Enumerate(string sidValue)
    {
        if (String.IsNullOrEmpty(sidValue))
            throw new ArgumentException("SID is required");
        var attributes = new LsaObjectAttributes();
        attributes.Length = (uint)Marshal.SizeOf(typeof(LsaObjectAttributes));
        IntPtr policy;
        uint status = LsaOpenPolicy(
            IntPtr.Zero,
            ref attributes,
            PolicyLookupNames,
            out policy);
        ThrowIfFailed(status, "open local security policy");

        GCHandle sidHandle = default(GCHandle);
        IntPtr rightsBuffer = IntPtr.Zero;
        try
        {
            var sid = new SecurityIdentifier(sidValue);
            var sidBytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(sidBytes, 0);
            sidHandle = GCHandle.Alloc(sidBytes, GCHandleType.Pinned);
            uint count;
            status = LsaEnumerateAccountRights(
                policy,
                sidHandle.AddrOfPinnedObject(),
                out rightsBuffer,
                out count);
            if (status == StatusObjectNameNotFound)
                return new string[0];
            ThrowIfFailed(status, "enumerate account rights");
            var rights = new string[checked((int)count)];
            int itemBytes = Marshal.SizeOf(typeof(LsaUnicodeString));
            for (int index = 0; index < rights.Length; ++index)
            {
                var item = (LsaUnicodeString)Marshal.PtrToStructure(
                    IntPtr.Add(rightsBuffer, checked(index * itemBytes)),
                    typeof(LsaUnicodeString));
                rights[index] = item.Buffer == IntPtr.Zero
                    ? String.Empty
                    : Marshal.PtrToStringUni(item.Buffer, item.Length / 2);
            }
            return rights;
        }
        finally
        {
            if (rightsBuffer != IntPtr.Zero) LsaFreeMemory(rightsBuffer);
            if (sidHandle.IsAllocated) sidHandle.Free();
            LsaClose(policy);
        }
    }

    private static void ThrowIfFailed(uint status, string operation)
    {
        if (status == 0) return;
        throw new Win32Exception(
            checked((int)LsaNtStatusToWinError(status)),
            operation + " failed");
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'CmuxLsaAccountRight').Type) {
    Add-Type -TypeDefinition $lsaSource -Language CSharp
}
$rights = @()
if ($Operation -eq "Enumerate") {
    $rights = @([CmuxLsaAccountRight]::Enumerate($Sid))
} else {
    [CmuxLsaAccountRight]::Apply($Sid, $Right, $Operation -eq "Add")
}

[ordered]@{
    schema_version = 2
    operation = $Operation.ToLowerInvariant()
    sid = $Sid
    right = $Right
    rights = @($rights)
} | ConvertTo-Json -Compress
