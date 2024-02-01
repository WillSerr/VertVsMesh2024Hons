#pragma once

#include "GameCore.h"
#include "CameraController.h"
#include "BufferManager.h"
#include "Renderer.h"
#include "Model.h"
#include "ShadowCamera.h"


using namespace std;

using Renderer::MeshSorter;

class MeshletViewer : public GameCore::IGameApp
{
public:

    MeshletViewer(void) {}

    virtual void Startup(void) override;
    virtual void Cleanup(void) override;

    virtual void Update(float deltaT) override;
    virtual void RenderScene(void) override;

private:

    Camera m_Camera;
    unique_ptr<CameraController> m_CameraController;

    D3D12_VIEWPORT m_MainViewport;
    D3D12_RECT m_MainScissor;

    ModelInstance m_ModelInst;
    ShadowCamera m_SunShadowCamera;
};