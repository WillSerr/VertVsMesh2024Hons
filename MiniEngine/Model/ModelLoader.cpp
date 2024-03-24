//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author(s):  James Stanard
//             Chuck Walbourn (ATG)
//
// This code depends on DirectXTex
//

#include "ModelLoader.h"
#include "Renderer.h"
#include "Model.h"
#include "glTF.h"
#include "ModelH3D.h"
#include "TextureManager.h"
#include "TextureConvert.h"
#include "GraphicsCommon.h"

#include <fstream>
#include <unordered_map>


#define  IS_RENDERING_MESHLETS 1

using namespace Renderer;
using namespace Graphics;

std::unordered_map<uint32_t, uint32_t> g_SamplerPermutations;

D3D12_CPU_DESCRIPTOR_HANDLE GetSampler(uint32_t addressModes)
{
    SamplerDesc samplerDesc;
    samplerDesc.AddressU = D3D12_TEXTURE_ADDRESS_MODE(addressModes & 0x3);
    samplerDesc.AddressV = D3D12_TEXTURE_ADDRESS_MODE(addressModes >> 2);
    return samplerDesc.CreateDescriptor();
}

void LoadMaterials(Model& model,
    const std::vector<MaterialTextureData>& materialTextures,
    const std::vector<std::wstring>& textureNames,
    const std::vector<uint8_t>& textureOptions,
    const std::wstring& basePath,
    bool useMPSOs = false)
{
    static_assert((_alignof(MaterialConstants) & 255) == 0, "CBVs need 256 byte alignment");

    // Load textures
    const uint32_t numTextures = (uint32_t)textureNames.size();
    model.textures.resize(numTextures);
    for (size_t ti = 0; ti < numTextures; ++ti)
    {
        std::wstring originalFile = basePath + textureNames[ti];
        CompileTextureOnDemand(originalFile, textureOptions[ti]);

        std::wstring ddsFile = Utility::RemoveExtension(originalFile) + L".dds";
        model.textures[ti] = TextureManager::LoadDDSFromFile(ddsFile);
    }

    // Generate descriptor tables and record offsets for each material
    const uint32_t numMaterials = (uint32_t)materialTextures.size();
    std::vector<uint32_t> tableOffsets(numMaterials);

    for (uint32_t matIdx = 0; matIdx < numMaterials; ++matIdx)
    {
        const MaterialTextureData& srcMat = materialTextures[matIdx];

        DescriptorHandle TextureHandles = Renderer::s_TextureHeap.Alloc(kNumTextures);
        uint32_t SRVDescriptorTable = Renderer::s_TextureHeap.GetOffsetOfHandle(TextureHandles);

        uint32_t DestCount = kNumTextures;
        uint32_t SourceCounts[kNumTextures] = { 1, 1, 1, 1, 1 };

        D3D12_CPU_DESCRIPTOR_HANDLE DefaultTextures[kNumTextures] =
        {
            GetDefaultTexture(kWhiteOpaque2D),
            GetDefaultTexture(kWhiteOpaque2D),
            GetDefaultTexture(kWhiteOpaque2D),
            GetDefaultTexture(kBlackTransparent2D),
            GetDefaultTexture(kDefaultNormalMap)
        };

        D3D12_CPU_DESCRIPTOR_HANDLE SourceTextures[kNumTextures];
        for (uint32_t j = 0; j < kNumTextures; ++j)
        {
            if (srcMat.stringIdx[j] == 0xffff)
                SourceTextures[j] = DefaultTextures[j];
            else
                SourceTextures[j] = model.textures[srcMat.stringIdx[j]].GetSRV();
        }

        g_Device->CopyDescriptors(1, &TextureHandles, &DestCount,
            DestCount, SourceTextures, SourceCounts, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

        // See if this combination of samplers has been used before.  If not, allocate more from the heap
        // and copy in the descriptors.
        uint32_t addressModes = srcMat.addressModes;
        auto samplerMapLookup = g_SamplerPermutations.find(addressModes);

        if (samplerMapLookup == g_SamplerPermutations.end())
        {
            DescriptorHandle SamplerHandles = Renderer::s_SamplerHeap.Alloc(kNumTextures);
            uint32_t SamplerDescriptorTable = Renderer::s_SamplerHeap.GetOffsetOfHandle(SamplerHandles);
            g_SamplerPermutations[addressModes] = SamplerDescriptorTable;
            tableOffsets[matIdx] = SRVDescriptorTable | SamplerDescriptorTable << 16;

            D3D12_CPU_DESCRIPTOR_HANDLE SourceSamplers[kNumTextures];
            for (uint32_t j = 0; j < kNumTextures; ++j)
            {
                SourceSamplers[j] = GetSampler(addressModes & 0xF);
                addressModes >>= 4;
            }
            g_Device->CopyDescriptors(1, &SamplerHandles, &DestCount,
                DestCount, SourceSamplers, SourceCounts, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
        }
        else
        {
            tableOffsets[matIdx] = SRVDescriptorTable | samplerMapLookup->second << 16;
        }
    }

    // Update table offsets for each mesh
    uint8_t* meshPtr = model.m_MeshData.get();
    for (uint32_t i = 0; i < model.m_NumMeshes; ++i)
    {
        Mesh& mesh = *(Mesh*)meshPtr;
        uint32_t offsetPair = tableOffsets[mesh.materialCBV];
        mesh.srvTable = offsetPair & 0xFFFF;
        mesh.samplerTable = offsetPair >> 16;
        if (!useMPSOs) {
            mesh.pso = Renderer::GetPSO(mesh.psoFlags);
        }
        else {
            mesh.pso = Renderer::GetMPSO(mesh.psoFlags);
        }
        meshPtr += sizeof(Mesh) + (mesh.numDraws - 1) * sizeof(Mesh::Draw);
    }
}

std::shared_ptr<Model> Renderer::LoadModel(const std::wstring& filePath, bool forceRebuild)
{
    const std::wstring miniFileName = Utility::RemoveExtension(filePath) + L".mini";
    const std::wstring fileName = Utility::RemoveBasePath(filePath);

    struct _stat64 sourceFileStat;
    struct _stat64 miniFileStat;
    std::ifstream inFile;
    FileHeader header;

    bool sourceFileMissing = _wstat64(filePath.c_str(), &sourceFileStat) == -1;
    bool miniFileMissing = _wstat64(miniFileName.c_str(), &miniFileStat) == -1;

    if (sourceFileMissing)
        forceRebuild = false;

    if (sourceFileMissing && miniFileMissing)
    {
        Utility::Printf("Error: Could not find %ws\n", fileName.c_str());
        return nullptr;
    }

    bool needBuild = forceRebuild;

    // Check if .mini file exists and it is newer than source file
    if (miniFileMissing || !sourceFileMissing && sourceFileStat.st_mtime > miniFileStat.st_mtime)
        needBuild = true;

    // Check if it's an older version of .mini
    if (!needBuild)
    {
        inFile = std::ifstream(miniFileName, std::ios::in | std::ios::binary);
        inFile.read((char*)&header, sizeof(FileHeader));
        if (strncmp(header.id, "MINI", 4) != 0 || header.version != CURRENT_MINI_FILE_VERSION)
        {
            Utility::Printf("Model version deprecated.  Rebuilding %ws...\n", fileName.c_str());
            needBuild = true;
            inFile.close();
        }
    }

    if (needBuild)
    {
        if (sourceFileMissing)
        {
            Utility::Printf("Error: Could not find %ws\n", fileName.c_str());
            return nullptr;
        }

        ModelData modelData;

        const std::wstring fileExt = Utility::ToLower(Utility::GetFileExtension(filePath));

        if (fileExt == L"gltf" || fileExt == L"glb")
        {
            glTF::Asset asset(filePath);
            if (!BuildModel(modelData, asset))
                return nullptr;
        }
        else if (fileExt == L"h3d")
        {
            ModelH3D modelh3d;
            const std::wstring basePath = Utility::GetBasePath(filePath);
            if (!modelh3d.Load(filePath) || !modelh3d.BuildModel(modelData, basePath))
                return nullptr;
        }
        else
        {
            Utility::Printf(L"Unsupported model file extension: %ws\n", fileExt.c_str());
            return nullptr;
        }

        if (!SaveModel(miniFileName, modelData))
            return nullptr;

        inFile = std::ifstream(miniFileName, std::ios::in | std::ios::binary);
        inFile.read((char*)&header, sizeof(FileHeader));
    }

    if (!inFile)
        return nullptr;

    ASSERT(strncmp(header.id, "MINI", 4) == 0 && header.version == CURRENT_MINI_FILE_VERSION);

    std::wstring basePath = Utility::GetBasePath(filePath);

    std::shared_ptr<Model> model(new Model);

    model->m_NumNodes = header.numNodes;
    model->m_SceneGraph.reset(new GraphNode[header.numNodes]);
    model->m_NumMeshes = header.numMeshes;
    model->m_MeshData.reset(new uint8_t[header.meshDataSize]);

    std::vector<char> rawByteBuffer(header.geometrySize);

	if (header.geometrySize > 0)
	{
		UploadBuffer modelData;
		modelData.Create(L"Model Data Upload", header.geometrySize);


		//inFile.read((char*)modelData.Map(), header.geometrySize);
        inFile.read(rawByteBuffer.data(), header.geometrySize);  //keep hold of values for meshlet generating
        memcpy(modelData.Map(), rawByteBuffer.data(), header.geometrySize);

		modelData.Unmap();
		model->m_DataBuffer.Create(L"Model Data", header.geometrySize, 1, modelData);



	}

    inFile.read((char*)model->m_SceneGraph.get(), header.numNodes * sizeof(GraphNode));
    inFile.read((char*)model->m_MeshData.get(), header.meshDataSize);

    //Generate Mesh renderer data
#define SAMPLESIZE 100
    const uint8_t* pMesh = model->m_MeshData.get();     // Pointer to current mesh
    //model->uniqueVertexIB.resize(16);
    int successfullRuns = 0;
    //DXGI_FORMAT format[SAMPLESIZE]{ DXGI_FORMAT::DXGI_FORMAT_UNKNOWN };
    //uint32_t DrawCount[SAMPLESIZE]{ 0 };   // Number of indices = 3 * number of triangles
    //uint32_t primCount[SAMPLESIZE]{ 0 };   // Number of indices = 3 * number of triangles
    //uint32_t startIndex[SAMPLESIZE]{ 0 };  // Offset to first index in index buffer 
    //uint32_t baseVertex[SAMPLESIZE]{ 0 };  // Offset to first vertex in vertex buffer
    //uint32_t DepthSizes[SAMPLESIZE]{ 0 };  // Offset to first vertex in vertex buffer
    //uint32_t DepthOffsets[SAMPLESIZE]{ 0 };
    //uint32_t VStrides[SAMPLESIZE]{ 0 };
    //uint32_t HighestIndex[SAMPLESIZE]{ 0 };
    //uint32_t TrueVertCount[SAMPLESIZE]{ 0 };
    for (uint32_t i = 0; i < model->m_NumMeshes; ++i)
    {
        const Mesh& mesh = *(const Mesh*)pMesh;

        size_t numFaces = mesh.draw[0].primCount / 3; //this seems wrong
        size_t numVerts = mesh.vbSize / mesh.vbStride;


        int MeshletCount = model->meshlets.size();  //makes sense at the end of the loop

        model->MeshletAssocMap[mesh.ibOffset] = DirectX::XMUINT4(model->meshlets.size() * sizeof(DirectX::Meshlet), model->uniqueVertexIB.size(),
                                                                    model->primitiveIndices.size() * sizeof(DirectX::MeshletTriangle), 0);

        //DXGI_FORMAT form = (DXGI_FORMAT)mesh.ibFormat;
        //uint32_t DepthSize = mesh.vbDepthSize;
        //uint32_t DepthOffset = mesh.vbDepthOffset;
        //uint32_t VStride = mesh.vbStride;
        //if (i < SAMPLESIZE) {
        //    format[i] = form;
        //    DepthSizes[i] = DepthSize;
        //    DepthOffsets[i] = DepthOffset;
        //    VStrides[i] = VStride;
        //}

        //uint32_t draws = mesh.numDraws;
        //if (mesh.numDraws > 0) {
        //    
        //    uint32_t prims = mesh.draw[0].primCount;   // Number of indices = 3 * number of triangles
        //    uint32_t startInd = mesh.draw[0].startIndex;  // Offset to first index in index buffer 
        //    uint32_t baseVert = mesh.draw[0].baseVertex;  // Offset to first vertex in vertex buffer

        //    if (i < SAMPLESIZE) {
        //        DrawCount[i] = draws;
        //        primCount[i] = prims;   // Number of indices = 3 * number of triangles
        //        startIndex[i] = startInd;  // Offset to first index in index buffer 
        //        baseVertex[i] = baseVert;  // Offset to first vertex in vertex buffer
        //    }
        //}

        

        //uint16_t ind16[SAMPLESIZE];
        //uint16_t ind32[SAMPLESIZE];
        //uint16_t highestIndex = 0;

        //size_t numIndices = mesh.ibSize / (sizeof(uint16_t));
        size_t numIndices = mesh.draw[0].primCount;// mesh.ibSize / (sizeof(uint16_t));

        assert(numIndices == mesh.ibSize / (sizeof(uint16_t)));

        auto indices = std::make_unique<uint16_t[]>(numIndices);
        for (size_t j = 0; j < numIndices; ++j) {
            uint16_t indj;
            memcpy(&indj, (rawByteBuffer.data() + mesh.ibOffset + (sizeof(uint16_t) * j)), (sizeof(uint16_t)));            
            indices[j] = indj;

            //if (highestIndex < indj)
            //    highestIndex = indj;

            //if (j < SAMPLESIZE) {
            //    ind16[j] = indices[j];

            //    uint16_t indj; 
            //    memcpy(&indj, (rawByteBuffer.data() + mesh.ibOffset), (sizeof(uint16_t)));
            //    ind32[j] = indj;
            //}

        }

        //if (i < SAMPLESIZE) {
        //    HighestIndex[i] = highestIndex;
        //}

        XMFLOAT3 pos[SAMPLESIZE]{XMFLOAT3(0,0,0)};
        //uint16_t vCount = 0;

        auto positions = std::make_unique<XMFLOAT3[]>(numVerts);
        for (size_t j = 0; j < numVerts; ++j) {
            XMFLOAT3 posj;
            memcpy(&posj, (rawByteBuffer.data() + mesh.vbOffset + (mesh.vbStride * j)), (sizeof(XMFLOAT3)));            
            positions[j] = posj;

            if (j < SAMPLESIZE) {
                pos[j] = posj;
            }

            //++vCount;
        }

        //if (i < SAMPLESIZE) {
        //    TrueVertCount[i] = vCount;
        //}





        HRESULT RES = ComputeMeshlets(
            indices.get(), numFaces,
            positions.get(),
            numVerts,
            nullptr,
            model->meshlets, model->uniqueVertexIB, model->primitiveIndices, 64, 126
        );

        MeshletCount = model->meshlets.size() - MeshletCount;

        model->MeshletAssocMap[mesh.ibOffset].w = MeshletCount;

        //auto align offset bytes to a multiple of 4
        if (model->uniqueVertexIB.size() % 4 != 0) {
            model->uniqueVertexIB.resize(model->uniqueVertexIB.size() + 4 - (model->uniqueVertexIB.size() % 4));
        }

        if (RES != S_OK)
        {
            bool oops = true;
            // Error
        }        
        else{
        successfullRuns++;
        }


        pMesh += sizeof(Mesh) + (mesh.numDraws - 1) * sizeof(Mesh::Draw);
    }

    rawByteBuffer.clear();
    rawByteBuffer.shrink_to_fit();

    {
        UploadBuffer MeshletsUpload;
        MeshletsUpload.Create(L"Meshlet Data Upload", model->meshlets.size() * sizeof(DirectX::Meshlet));
        memcpy(MeshletsUpload.Map(), model->meshlets.data(), model->meshlets.size() * sizeof(DirectX::Meshlet));
        MeshletsUpload.Unmap();
        model->m_MeshletBuffer.Create(L"Meshlet Data Buffer", model->meshlets.size(), sizeof(DirectX::Meshlet), MeshletsUpload);
        model->meshlets.clear();
        model->meshlets.shrink_to_fit();
    }   


    {
        UploadBuffer uniqueVertexUpload;
        uniqueVertexUpload.Create(L"Unique Vertex Upload", model->uniqueVertexIB.size() * sizeof(uint8_t));
        memcpy(uniqueVertexUpload.Map(), model->uniqueVertexIB.data(), model->uniqueVertexIB.size() * sizeof(uint8_t));
        uniqueVertexUpload.Unmap();
        model->m_uniqueVertexIB.Create(L"Unique Vertex Data Buffer", model->uniqueVertexIB.size() / 2, sizeof(uint16_t), uniqueVertexUpload); //indices are packed into 16bits
        model->uniqueVertexIB.clear();
        model->uniqueVertexIB.shrink_to_fit();
    }


    {
        UploadBuffer PrimitivesUpload;
        PrimitivesUpload.Create(L"Primitive Indices Upload", model->primitiveIndices.size() * sizeof(DirectX::MeshletTriangle));
        memcpy(PrimitivesUpload.Map(), model->primitiveIndices.data(), model->primitiveIndices.size() * sizeof(DirectX::MeshletTriangle));
        PrimitivesUpload.Unmap();
        model->m_primitiveIndices.Create(L"Primitive Indices Data Buffer", model->primitiveIndices.size(), sizeof(DirectX::MeshletTriangle), PrimitivesUpload);
        model->primitiveIndices.clear();
        model->primitiveIndices.shrink_to_fit();
    }

    




	if (header.numMaterials > 0)
	{
		UploadBuffer materialConstants;
		materialConstants.Create(L"Material Constant Upload", header.numMaterials * sizeof(MaterialConstants));
		MaterialConstants* materialCBV = (MaterialConstants*)materialConstants.Map();
		for (uint32_t i = 0; i < header.numMaterials; ++i)
		{
			inFile.read((char*)materialCBV, sizeof(MaterialConstantData));
			materialCBV++;
		}
		materialConstants.Unmap();
		model->m_MaterialConstants.Create(L"Material Constants", header.numMaterials, sizeof(MaterialConstants), materialConstants);
	}

    // Read material texture and sampler properties so we can load the material
    std::vector<MaterialTextureData> materialTextures(header.numMaterials);
    inFile.read((char*)materialTextures.data(), header.numMaterials * sizeof(MaterialTextureData));

    std::vector<std::wstring> textureNames(header.numTextures);
    for (uint32_t i = 0; i < header.numTextures; ++i)
    {
        std::string utf8TextureName;
        std::getline(inFile, utf8TextureName, '\0');
        textureNames[i] = Utility::UTF8ToWideString(utf8TextureName);
    }

    std::vector<uint8_t> textureOptions(header.numTextures);
    inFile.read((char*)textureOptions.data(), header.numTextures * sizeof(uint8_t));



#ifdef IS_RENDERING_MESHLETS
    LoadMaterials(*model, materialTextures, textureNames, textureOptions, basePath, true);
#else
   LoadMaterials(*model, materialTextures, textureNames, textureOptions, basePath);
#endif // IS_RENDERING_MESHLETS

    
    

    model->m_BoundingSphere = Math::BoundingSphere(*(XMFLOAT4*)header.boundingSphere);
    model->m_BoundingBox = AxisAlignedBox(Vector3(*(XMFLOAT3*)header.minPos), Vector3(*(XMFLOAT3*)header.maxPos));

    // Load animation data
    model->m_NumAnimations = header.numAnimations;

    if (header.numAnimations > 0)
    {
        ASSERT(header.keyFrameDataSize > 0 && header.numAnimationCurves > 0);
        model->m_KeyFrameData.reset(new uint8_t[header.keyFrameDataSize]);
        inFile.read((char*)model->m_KeyFrameData.get(), header.keyFrameDataSize);
        model->m_CurveData.reset(new AnimationCurve[header.numAnimationCurves]);
        inFile.read((char*)model->m_CurveData.get(), header.numAnimationCurves * sizeof(AnimationCurve));
        model->m_Animations.reset(new AnimationSet[header.numAnimations]);
        inFile.read((char*)model->m_Animations.get(), header.numAnimations * sizeof(AnimationSet));
    }

    model->m_NumJoints = header.numJoints;

    if (header.numJoints > 0)
    {
        model->m_JointIndices.reset(new uint16_t[header.numJoints]);
        inFile.read((char*)model->m_JointIndices.get(), header.numJoints * sizeof(uint16_t));
        model->m_JointIBMs.reset(new Matrix4[header.numJoints]);
        inFile.read((char*)model->m_JointIBMs.get(), header.numJoints * sizeof(Matrix4));
    }

    return model;
}
