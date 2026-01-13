#include "CaptureSource.h"
#include <initguid.h>
#include <olectl.h>
#include <stdio.h>

// Self-definition of GUIDs to avoid link errors if not in libs
DEFINE_GUID(CLSID_AntigravityCam, 0x8e14549a, 0xdb61, 0x4309, 0xaf, 0xa1, 0x35,
            0x78, 0xe9, 0x27, 0xe9, 0x33);

// Setup data for registration
const AMOVIESETUP_MEDIATYPE sudOpPinTypes = {
    &MEDIATYPE_Video,  // Major type
    &MEDIASUBTYPE_NULL // Minor type
};

const AMOVIESETUP_PIN sudOpPin = {
    const_cast<LPWSTR>(L"Output"), // Pin Name
    FALSE,                         // Rendered?
    TRUE,                          // Output?
    FALSE,                         // Zero?
    FALSE,                         // Many?
    &CLSID_NULL,                   // Connects to filter
    NULL,                          // Connects to pin
    1,                             // Number of types
    &sudOpPinTypes                 // Pin details
};

const AMOVIESETUP_FILTER sudVCam = {
    &CLSID_AntigravityCam,  // Filter CLSID
    L"Antigravity iOS Cam", // Filter Name
    MERIT_DO_NOT_USE,       // Merit
    1,                      // Pin Count
    &sudOpPin               // Pin Details
};

// Required for DLL Entry
CFactoryTemplate g_Templates[] = {{L"Antigravity iOS Cam",
                                   &CLSID_AntigravityCam, CVCam::CreateInstance,
                                   NULL, &sudVCam}};
int g_cTemplates = sizeof(g_Templates) / sizeof(g_Templates[0]);

// DLL Entry Points
STDAPI DllRegisterServer() { return AMovieDllRegisterServer2(TRUE); }
STDAPI DllUnregisterServer() { return AMovieDllRegisterServer2(FALSE); }
extern "C" BOOL WINAPI DllEntryPoint(HINSTANCE, ULONG, LPVOID);

BOOL APIENTRY DllMain(HANDLE hModule, DWORD dwReason, LPVOID lpReserved) {
  return DllEntryPoint((HINSTANCE)(hModule), dwReason, lpReserved);
}

// CVCam Implementation
CUnknown *WINAPI CVCam::CreateInstance(LPUNKNOWN lpunk, HRESULT *phr) {
  CUnknown *punk = new CVCam(lpunk, phr);
  if (punk == NULL)
    *phr = E_OUTOFMEMORY;
  return punk;
}

CVCam::CVCam(LPUNKNOWN lpunk, HRESULT *phr)
    : CSource(NAME("Antigravity Cam"), lpunk, CLSID_AntigravityCam) {
  CVCamStream *pPin = new CVCamStream(phr, this, L"Output");
  if (pPin == NULL)
    *phr = E_OUTOFMEMORY;
}

STDMETHODIMP CVCam::NonDelegatingQueryInterface(REFIID riid, void **ppv) {
  // Add logic here if implementing specific interfaces like IAMStreamConfig
  return CSource::NonDelegatingQueryInterface(riid, ppv);
}

// CVCamStream Implementation
CVCamStream::CVCamStream(HRESULT *phr, CVCam *pParent, LPCWSTR pPinName)
    : CSourceStream(NAME("Output"), phr, pParent, pPinName) {
  m_hMapFile = NULL;
  m_pSharedMem = NULL;
  m_lastReadSequence = 0;
}

CVCamStream::~CVCamStream() {
  // Cleanup handled in OnThreadDestroy usually
}

HRESULT CVCamStream::OnThreadCreate() {
  InitSharedMemory();
  return S_OK;
}

HRESULT CVCamStream::OnThreadDestroy() {
  if (m_pSharedMem)
    UnmapViewOfFile(m_pSharedMem);
  if (m_hMapFile)
    CloseHandle(m_hMapFile);
  m_pSharedMem = NULL;
  m_hMapFile = NULL;
  return S_OK;
}

void CVCamStream::InitSharedMemory() {
  m_hMapFile = OpenFileMappingA(FILE_MAP_READ, FALSE, SHARED_MEMORY_NAME);
  if (m_hMapFile) {
    m_pSharedMem = (SharedMemoryLayout *)MapViewOfFile(
        m_hMapFile, FILE_MAP_READ, 0, 0, sizeof(SharedMemoryLayout));
  }
}

HRESULT CVCamStream::FillBuffer(IMediaSample *pms) {
  CheckPointer(pms, E_POINTER);

  // Default to black if no data
  BYTE *pData;
  pms->GetPointer(&pData);
  long size = pms->GetSize();

  // DEBUG: Verify buffer sizes match
  if (size != FRAME_BUFFER_SIZE) {
    OutputDebugStringA("WARNING: Buffer size mismatch!\n");
  }

  // Check Shared Memory
  if (!m_pSharedMem) {
    InitSharedMemory();
  }

  // Safety clear to black
  memset(pData, 0, size);

  // DEBUG: Frame counter
  static int frameCount = 0;
  if (++frameCount % 300 == 0) { // Every 10 seconds at 30fps
    char debugMsg[64];
    sprintf_s(debugMsg, "VirtualCam: Delivered %d frames\n", frameCount);
    OutputDebugStringA(debugMsg);
  }

  if (m_pSharedMem && m_pSharedMem->magic == 0x43424557) {
    // Simple polling approach (blocking here would block the graph, but
    // FillBuffer is called in a loop) ideally we wait for event, but for MVP we
    // just copy latest
    memcpy(pData, (void *)m_pSharedMem->data, FRAME_BUFFER_SIZE);
    m_lastReadSequence = m_pSharedMem->write_sequence;
  }

  // Set timing
  CRefTime now;
  m_pFilter->StreamTime(now);
  REFERENCE_TIME rtStart = now;
  REFERENCE_TIME rtEnd = rtStart + (10000000 / VIDEO_FPS);
  pms->SetTime(&rtStart, &rtEnd);
  pms->SetSyncPoint(TRUE);

  // Sleep to maintain framerate roughly (simple rate control)
  Sleep(1000 / VIDEO_FPS);

  return S_OK;
}

HRESULT CVCamStream::DecideBufferSize(IMemAllocator *pAlloc,
                                      ALLOCATOR_PROPERTIES *pProperties) {
  CheckPointer(pAlloc, E_POINTER);
  CheckPointer(pProperties, E_POINTER);

  CAutoLock cAutoLock(m_pFilter->pStateLock());

  VIDEOINFOHEADER *pvi = (VIDEOINFOHEADER *)m_mt.Format();
  pProperties->cBuffers = 1;
  pProperties->cbBuffer = pvi->bmiHeader.biSizeImage;

  ALLOCATOR_PROPERTIES Actual;
  HRESULT hr = pAlloc->SetProperties(pProperties, &Actual);
  if (FAILED(hr))
    return hr;

  if (Actual.cbBuffer < pProperties->cbBuffer)
    return E_FAIL;
  return S_OK;
}

HRESULT CVCamStream::CheckMediaType(const CMediaType *pMediaType) {
  if (*pMediaType != m_mt)
    return E_INVALIDARG;
  return S_OK;
}

HRESULT CVCamStream::GetMediaType(int iPosition, CMediaType *pmt) {
  if (iPosition < 0)
    return E_INVALIDARG;
  if (iPosition > 0)
    return VFW_S_NO_MORE_ITEMS;

  VIDEOINFOHEADER *pvi =
      (VIDEOINFOHEADER *)pmt->AllocFormatBuffer(sizeof(VIDEOINFOHEADER));
  ZeroMemory(pvi, sizeof(VIDEOINFOHEADER));

  pvi->bmiHeader.biCompression = BI_RGB;
  pvi->bmiHeader.biBitCount = 32;
  pvi->bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  pvi->bmiHeader.biWidth = VIDEO_WIDTH;
  pvi->bmiHeader.biHeight = VIDEO_HEIGHT;
  pvi->bmiHeader.biPlanes = 1;
  pvi->bmiHeader.biSizeImage = GetBitmapSize(&pvi->bmiHeader);
  pvi->bmiHeader.biClrImportant = 0;

  // Average Time Per Frame (100ns units)
  pvi->AvgTimePerFrame = 10000000 / VIDEO_FPS;

  pmt->SetType(&MEDIATYPE_Video);
  pmt->SetFormatType(&FORMAT_VideoInfo);
  pmt->SetTemporalCompression(FALSE);

  // SUBTYPE_RGB32
  const GUID subtype = MEDIASUBTYPE_RGB32;
  pmt->SetSubtype(&subtype);
  pmt->SetSampleSize(pvi->bmiHeader.biSizeImage);

  return S_OK;
}

HRESULT CVCamStream::SetMediaType(const CMediaType *pmt) {
  // Should verify it works
  return CSourceStream::SetMediaType(pmt);
}
