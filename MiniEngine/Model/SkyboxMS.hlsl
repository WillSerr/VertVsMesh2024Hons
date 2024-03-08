
#include "MeshCommon.hlsli"

#ifdef ENABLE_SKINNING
//#undef ENABLE_SKINNING
#endif

struct MeshConstants
{
    float4x4 ProjInverse;
    float3x3 ViewInverse;
};

struct GlobalConstants
{
    float4x4 ViewProjMatrix;
    float4x4 SunShadowMatrix;
    float3 ViewerPos;
    float3 SunDirection;
    float3 SunIntensity;
};

#ifdef ENABLE_SKINNING
struct Joint
{
    float4x4 PosMatrix;
    float4x3 NrmMatrix; // Inverse-transpose of PosMatrix
};

StructuredBuffer<Joint> Joints : register(t20);
#endif

struct Vertex
{
    float3 position : POSITION;
#ifdef ENABLE_ALPHATEST
    float2 uv0 : TEXCOORD0;
#endif
#ifdef ENABLE_SKINNING
    uint4 jointIndices : BLENDINDICES;
    float4 jointWeights : BLENDWEIGHT;
#endif
};

struct VSOutput
{
    float4 position : SV_POSITION;
    float3 viewDir : TEXCOORD3;
};


ConstantBuffer<MeshConstants> Constants : register(b0);
ConstantBuffer<GlobalConstants> Globals : register(b1);

StructuredBuffer<Vertex> Vertices : register(t21);
StructuredBuffer<Meshlet> Meshlets : register(t22);



VSOutput GetVertexAttributes(uint meshletIndex, uint vertexIndex)
{
    float2 ScreenUV = float2(uint2(vertexIndex, vertexIndex << 1) & 2);
    float4 ProjectedPos = float4(lerp(float2(-1, 1), float2(1, -1), ScreenUV), 0, 1);
    float4 PosViewSpace = mul(Constants.ProjInverse, ProjectedPos);

    VSOutput vsOutput;
    vsOutput.position = ProjectedPos;
    vsOutput.viewDir = mul(Constants.ViewInverse, PosViewSpace.xyz / PosViewSpace.w);
    
    return vsOutput;
}


[RootSignature(Mesh_Renderer_RootSig)]
[NumThreads(128, 1, 1)]
[OutputTopology("triangle")]
void main(
    uint gtid : SV_GroupThreadID,
    uint gid : SV_GroupID,
    out indices uint3 tris[126],
    out vertices VSOutput verts[64]
)
{
    Meshlet m = Meshlets[MeshInfo.MeshletOffset + gid]; //MeshInfo.MeshletOffset + gid]; meshlet is passed at the correct position

    SetMeshOutputCounts(m.VertCount, m.PrimCount);

    if (gtid < m.PrimCount)
    {
        tris[gtid] = GetPrimitive(m, gtid);
    }

    if (gtid < m.VertCount)
    {
        uint vertexIndex = GetVertexIndex(m, gtid);
        verts[gtid] = GetVertexAttributes(gid, vertexIndex);
    }
}