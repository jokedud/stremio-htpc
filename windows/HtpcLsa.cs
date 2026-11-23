using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

// LSA private data, the store Windows reads the auto-logon DefaultPassword from.
public static class HtpcLsa {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attributes, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr handle, ref LSA_UNICODE_STRING key, IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr handle, ref LSA_UNICODE_STRING key, out IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr buffer);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    const uint NotFound = 0xC0000034;

    static LSA_UNICODE_STRING Make(string value) {
        var result = new LSA_UNICODE_STRING();
        result.Buffer = Marshal.StringToHGlobalUni(value);
        result.Length = (ushort)(value.Length * 2);
        result.MaximumLength = (ushort)(value.Length * 2 + 2);
        return result;
    }

    static IntPtr Open() {
        var attributes = new LSA_OBJECT_ATTRIBUTES();
        attributes.Length = Marshal.SizeOf(attributes);
        IntPtr handle;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x00000004 | 0x00000020, out handle);
        if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        return handle;
    }

    // A null value deletes the secret.
    public static void Store(string name, string value) {
        IntPtr handle = Open();
        var key = Make(name);
        var data = value == null ? new LSA_UNICODE_STRING() : Make(value);
        IntPtr dataPtr = IntPtr.Zero;
        try {
            if (value != null) {
                dataPtr = Marshal.AllocHGlobal(Marshal.SizeOf(data));
                Marshal.StructureToPtr(data, dataPtr, false);
            }
            uint status = LsaStorePrivateData(handle, ref key, dataPtr);
            if (status != 0 && !(value == null && status == NotFound)) throw new Win32Exception(LsaNtStatusToWinError(status));
        } finally {
            if (dataPtr != IntPtr.Zero) Marshal.FreeHGlobal(dataPtr);
            if (data.Buffer != IntPtr.Zero) {
                Marshal.Copy(new byte[data.Length], 0, data.Buffer, data.Length);
                Marshal.FreeHGlobal(data.Buffer);
            }
            Marshal.FreeHGlobal(key.Buffer);
            LsaClose(handle);
        }
    }

    // Returns null when the secret does not exist.
    public static string Retrieve(string name) {
        IntPtr handle = Open();
        var key = Make(name);
        IntPtr data;
        try {
            uint status = LsaRetrievePrivateData(handle, ref key, out data);
            if (status == NotFound) return null;
            if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
            var value = (LSA_UNICODE_STRING)Marshal.PtrToStructure(data, typeof(LSA_UNICODE_STRING));
            string result = Marshal.PtrToStringUni(value.Buffer, value.Length / 2);
            LsaFreeMemory(data);
            return result;
        } finally {
            Marshal.FreeHGlobal(key.Buffer);
            LsaClose(handle);
        }
    }
}
