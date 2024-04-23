#ifndef __MCOMMON_HLSLI__
#define __MCOMMON_HLSLI__


#define Mesh_Renderer_RootSig \
    "CBV(b0, visibility = SHADER_VISIBILITY_MESH), " \
    "CBV(b0, visibility = SHADER_VISIBILITY_PIXEL), " \
    "DescriptorTable(SRV(t0, numDescriptors = 10), visibility = SHADER_VISIBILITY_PIXEL)," \
    "DescriptorTable(Sampler(s0, numDescriptors = 10), visibility = SHADER_VISIBILITY_PIXEL)," \
    "DescriptorTable(SRV(t10, numDescriptors = 10), visibility = SHADER_VISIBILITY_PIXEL)," \
    "CBV(b1), " \
    "RootConstants(b2, num32bitconstants=2, visibility = SHADER_VISIBILITY_MESH), " \
    "SRV(t20, visibility = SHADER_VISIBILITY_MESH), " \
    "SRV(t21, visibility = SHADER_VISIBILITY_MESH)," \
    "SRV(t22, visibility = SHADER_VISIBILITY_MESH)," \
    "SRV(t23, visibility = SHADER_VISIBILITY_MESH)," \
    "SRV(t24, visibility = SHADER_VISIBILITY_MESH)," \
    "StaticSampler(s10, maxAnisotropy = 8, visibility = SHADER_VISIBILITY_PIXEL)," \
    "StaticSampler(s11, visibility = SHADER_VISIBILITY_PIXEL," \
        "addressU = TEXTURE_ADDRESS_CLAMP," \
        "addressV = TEXTURE_ADDRESS_CLAMP," \
        "addressW = TEXTURE_ADDRESS_CLAMP," \
        "comparisonFunc = COMPARISON_GREATER_EQUAL," \
        "filter = FILTER_MIN_MAG_LINEAR_MIP_POINT)," \
    "StaticSampler(s12, maxAnisotropy = 8, visibility = SHADER_VISIBILITY_PIXEL)" 


// Common (static) samplers
SamplerState defaultSampler : register(s10);
SamplerComparisonState shadowSampler : register(s11);
SamplerState cubeMapSampler : register(s12);




struct Meshlet
{
    uint VertCount;
    uint VertOffset;
    uint PrimCount;
    uint PrimOffset;
};


struct MeshletInfo
{
    uint IndexBytes;
    uint MeshletOffset;
};

ByteAddressBuffer UniqueVertexIndices : register(t23);
StructuredBuffer<uint> PrimitiveIndices : register(t24);
ConstantBuffer<MeshletInfo> MeshInfo : register(b2);

/////
// Data Loaders
uint3 UnpackPrimitive(uint primitive)
{
    // Unpacks a 10 bits per index triangle from a 32-bit uint.
    return uint3(primitive & 0x3FF, (primitive >> 10) & 0x3FF, (primitive >> 20) & 0x3FF);
}

uint3 GetPrimitive(Meshlet m, uint index)
{
    return UnpackPrimitive(PrimitiveIndices[m.PrimOffset + index]);
}

uint GetVertexIndex(Meshlet m, uint localIndex)
{
    localIndex = m.VertOffset + localIndex;

    //INDICES ARE 16-BIT
    if (MeshInfo.IndexBytes == 4) // 32-bit Vertex Indices
    {
        return UniqueVertexIndices.Load(localIndex * 4);
    }
    else // 16-bit Vertex Indices
    {
    
    // Byte address must be 4-byte aligned.
    uint wordOffset = (localIndex & 0x1);
    uint byteOffset = (localIndex / 2) * 4;

    // Grab the pair of 16-bit indices, shift & mask off proper 16-bits.
    uint indexPair = UniqueVertexIndices.Load(byteOffset);
    uint index = (indexPair >> (wordOffset * 16)) & 0xffff;

    return index;

    }
}


#endif