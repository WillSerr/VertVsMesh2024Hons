
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
    float3 Normal;
};

struct Meshlet
{
    uint VertCount;
    uint VertOffset;
    uint PrimCount;
    uint PrimOffset;
};

//struct MeshInfo
//{
//    uint IndexBytes;
//    uint MeshletOffset;
//};

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
ByteAddressBuffer UniqueVertexIndices : register(t23);
StructuredBuffer<uint> PrimitiveIndices : register(t24);

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
    //if (MeshInfo.IndexBytes == 4) // 32-bit Vertex Indices
    //{
    //    return UniqueVertexIndices.Load(localIndex * 4);
    //}
    //else // 16-bit Vertex Indices
    //{
        // Byte address must be 4-byte aligned.
        uint wordOffset = (localIndex & 0x1);
        uint byteOffset = (localIndex / 2) * 4;

        // Grab the pair of 16-bit indices, shift & mask off proper 16-bits.
        uint indexPair = UniqueVertexIndices.Load(byteOffset);
        uint index = (indexPair >> (wordOffset * 16)) & 0xffff;

        return index;
    //}
}

VSOutput GetVertexAttributes(uint meshletIndex, uint vertexIndex)
{
    Vertex v = Vertices[vertexIndex];

    float4 position = float4(v.Position, 1.0);
    float3 normal = v.Normal * 2 - 1;
    
    VSOutput vout;
    vout.worldPos = mul(Constants.WorldMatrix, position).xyz;
    vout.position = mul(Globals.ViewProjMatrix, float4(vout.worldPos, 1.0));
    vout.sunShadowCoord = mul(Globals.SunShadowMatrix, float4(vout.worldPos, 1.0)).xyz;
    vout.normal = mul(Constants.WorldIT, normal);

    return vout;
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
    Meshlet m = Meshlets[gid]; //MeshInfo.MeshletOffset + gid]; meshlet is passed at the correct position

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