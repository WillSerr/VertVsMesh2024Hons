
#include "MeshCommon.hlsli"


struct MeshConstants
{
    float4x4 WorldMatrix; // Object to world
    float3x3 WorldIT; // Object normal to world normal
};

struct GlobalConstants
{
    float4x4 ViewProjMatrix;
    float4x4 SunShadowMatrix;
    float3 ViewerPos;
    float3 SunDirection;
    float3 SunIntensity;
};

struct Vertex
{
    float3 Position;
    uint Normal;
#ifndef NO_TANGENT_FRAME
    uint tangent : TANGENT;
#endif
    uint uv0 : TEXCOORD0;
#ifndef NO_SECOND_UV
    uint uv1 : TEXCOORD1;
#endif
#ifdef ENABLE_SKINNING
    uint4 jointIndices : BLENDINDICES;
    float4 jointWeights : BLENDWEIGHT;
#endif
};

struct VSOutput
{
    float4 position : SV_POSITION;
    float3 normal : NORMAL;
#ifndef NO_TANGENT_FRAME
    float4 tangent : TANGENT;
#endif
    float2 uv0 : TEXCOORD0;
#ifndef NO_SECOND_UV
    float2 uv1 : TEXCOORD1;
#endif
    float3 worldPos : TEXCOORD2;
    float3 sunShadowCoord : TEXCOORD3;
};


ConstantBuffer<MeshConstants> Constants : register(b0);
ConstantBuffer<GlobalConstants> Globals: register(b1);

StructuredBuffer<Vertex> Vertices : register(t21);
StructuredBuffer<Meshlet> Meshlets : register(t22);

float f10tof32(uint float10)
{    
    uint exponent = (float10 & 0x3E0) << 16;
    uint mantissa = float10 & 0x1F;
    uint value = exponent | 30000000 | mantissa;
    
    return float(value);
}

float3 ExtractNormal(uint r10g10b10a2)
{
    float3 values;
    values.x = f10tof32(r10g10b10a2);
    values.y = f10tof32((r10g10b10a2 >> 10));
    values.z = f10tof32((r10g10b10a2 >> 20));
    
    return normalize(values * 2 - 1);

}

float4 ExtractTangent(uint r10g10b10a2)
{
    float4 values;
    values.x = f10tof32(r10g10b10a2);
    values.y = f10tof32((r10g10b10a2 >> 10));
    values.z = f10tof32((r10g10b10a2 >> 20));
    values.w = r10g10b10a2 >> 31; //last bit is binary
    
    return values * 2 - 1;

}

float2 ReadUVs(uint packedUV)
{
    float2 texcoord = float2(1, 1);
    uint floatValue = 0;
    
    texcoord.x = f16tof32(packedUV);
    
    texcoord.y = f16tof32(packedUV >> 16);
    
    return texcoord;
}

VSOutput GetVertexAttributes(uint meshletIndex, uint vertexIndex)
{
    Vertex v = Vertices[vertexIndex];
    VSOutput vsOutput;
    
    

    float4 position = float4(v.Position, 1.0);
    float3 normal = ExtractNormal(v.Normal);
#ifndef NO_TANGENT_FRAME
    float4 tangent = ExtractTangent(v.tangent);
#endif

#ifdef ENABLE_SKINNING
    // I don't like this hack.  The weights should be normalized already, but something is fishy.
    float4 weights = v.jointWeights / dot(v.jointWeights, 1);

    float4x4 skinPosMat =
        Joints[v.jointIndices.x].PosMatrix * weights.x +
        Joints[v.jointIndices.y].PosMatrix * weights.y +
        Joints[v.jointIndices.z].PosMatrix * weights.z +
        Joints[v.jointIndices.w].PosMatrix * weights.w;

    position = mul(skinPosMat, position);

    float4x3 skinNrmMat =
        Joints[v.jointIndices.x].NrmMatrix * weights.x +
        Joints[v.jointIndices.y].NrmMatrix * weights.y +
        Joints[v.jointIndices.z].NrmMatrix * weights.z +
        Joints[v.jointIndices.w].NrmMatrix * weights.w;

    normal = mul(skinNrmMat, normal).xyz;
#ifndef NO_TANGENT_FRAME
    tangent.xyz = mul(skinNrmMat, tangent.xyz).xyz;
#endif

#endif

    vsOutput.worldPos = mul(Constants.WorldMatrix, position).xyz;
    vsOutput.position = mul(Globals.ViewProjMatrix, float4(vsOutput.worldPos, 1.0));
    vsOutput.sunShadowCoord = mul(Globals.SunShadowMatrix, float4(vsOutput.worldPos, 1.0)).xyz;
    vsOutput.normal = mul(Constants.WorldIT, normal);
#ifndef NO_TANGENT_FRAME
    vsOutput.tangent = float4(mul(Constants.WorldIT, tangent.xyz), tangent.w);
#endif
    vsOutput.uv0 = ReadUVs(v.uv0);
#ifndef NO_SECOND_UV
    vsOutput.uv1 = ReadUVs(v.uv1);
#endif

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

//// This gets read from the user vertex SRV
//struct MyInputVertex
//{
//    float4 something : SOMETHING;
//};

//// This is a bunch of outparams for the Mesh shader. At least SV_Position must be present.
//struct MyOutputVertex
//{
//    float4 ndcPos : SV_Position;
//    float4 someAttr : ATTRIBUTE;
//};

//#define NUM_THREADS_X 96
//#define NUM_THREADS_Y 1
//#define NUM_THREADS_Z 1

//#define MAX_NUM_VERTS 252
//#define MAX_NUM_PRIMS (MAX_NUM_VERTS / 3)

//groupshared uint indices[MAX_NUM_VERTS];

//// We output no more than 1 primitive per input primitive
//// Input primitive has up to 3 input vertices and up to 3 output vertices
//[outputtopology("triangle")]
//[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
//void PassthroughMeshshader(
//    in  uint tid : SV_DispatchThreadID,
//    in  uint tig : SV_GroupIndex,
//    out vertices    MyOutputVertex verts[MAX_NUM_VERTS],
//    out indices uint3 triangles[MAX_NUM_PRIMS])
//{
//    // Use a helper to read and deduplicate indices
//    // We need to read no more than MAX_NUM_VERTS indices and no more
//    // than MAX_NUM_PRIMS primitives. An offline index pre-process
//    // ensures that each threadgroup gets an efficiently packed
//    // workload. Because it's preprocessed, we only need to give the
//    // helper function our threadgroup index.
//    uint numVerticesInThreadGroup;
//    uint numPrimitivesInThreadGroup;
//    uint packedConnectivityForThisLanesPrimitive;
//    ReadTriangleListIndices(
//        numVerticesInThreadGroup, // out
//        numPrimitivesInThreadGroup, // out
//        indices, // out
//        packedConnectivityForThisLanesPrimitive, // out
//        indexBufferSRV, // SRV with the offline made IB
//        tig, // Thread group index
//        false); // 32 bit per index

//    // Set number of outputs
//    SetMeshOutputCounts(numVerticesInThreadGroup, numPrimitivesInThreadGroup);

//    // Transform the vertices and write them  
//    uint numVertexIterations = numVerticesInThreadGroup / NUM_THREADS_X;
//    for (uint i = 0;i <= numVertexIterations;++i)
//    {
//        uint localVertexIndex = i * NUM_THREADS_X + tig;
    
//        if (localVertexIndex < numVerticesInThreadGroup)
//        {
//            MyOutputVertex v = User_LoadAndProcessVertex(indices[localVertexIndex]);
//            verts[localVertexIndex] = v;
//        }
//    }

//    // Now write the primitives
//    if (tig < numPrimitivesInThreadGroup)
//    {
//        triangles[tig] = uint3(
//            packedConnectivityForThisLanesPrimitive & 0xFF,
//            (packedConnectivityForThisLanesPrimitive >> 8) & 0xFF,
//            (packedConnectivityForThisLanesPrimitive >> 16) & 0xFF);
//    }
//}