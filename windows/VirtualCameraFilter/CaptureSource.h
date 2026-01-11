#pragma once
#include <streams.h> // DirectShow BaseClasses
#include "../common/SharedMemory.h"

// UUIDs for our Filter using a generated GUID (Do not change this once registered)
// {8E14549A-DB61-4309-AFA1-3578E927E933}
DEFINE_GUID(CLSID_AntigravityCam, 
0x8e14549a, 0xdb61, 0x4309, 0xaf, 0xa1, 0x35, 0x78, 0xe9, 0x27, 0xe9, 0x33);

class CVCamStream;

// Main Filter Class
class CVCam : public CSource {
public:
    static CUnknown * WINAPI CreateInstance(LPUNKNOWN lpunk, HRESULT *phr);
    STDMETHODIMP NonDelegatingQueryInterface(REFIID riid, void **ppv);

    CVCam(LPUNKNOWN lpunk, HRESULT *phr);
};

// Output Pin Class
class CVCamStream : public CSourceStream {
public:
    CVCamStream(HRESULT *phr, CVCam *pParent, LPCWSTR pPinName);
    ~CVCamStream();

    // CSourceStream
    HRESULT FillBuffer(IMediaSample *pms);
    HRESULT DecideBufferSize(IMemAllocator *pIMemAlloc, ALLOCATOR_PROPERTIES *pProperties);
    HRESULT CheckMediaType(const CMediaType *pMediaType);
    HRESULT GetMediaType(int iPosition, CMediaType *pmt);
    HRESULT SetMediaType(const CMediaType *pmt);
    HRESULT OnThreadCreate();
    HRESULT OnThreadDestroy(); // Cleanup shared mem

private:
    HANDLE m_hMapFile;
    SharedMemoryLayout* m_pSharedMem;
    uint32_t m_lastReadSequence;
    CCritSec m_cSharedState; // Lock
    
    void InitSharedMemory();
};
