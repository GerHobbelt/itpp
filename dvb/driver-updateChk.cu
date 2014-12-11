
#include "driver-updateChk.cuh"

#include <cuda_runtime.h>

#include <iostream>
using namespace std;


#define		TABLE_SIZE_DINT2	300
#define		MAX_CHECK_NODE		10
#define		MAX_VAR_NODE		19
#define		VAR_SIZE_CODE		16200
#define		CHECK_SIZE_CODE		8073
#define		SIZE_BLOCK			256
#define		SIZE_BLOCK_2D_X		32

#define		USE_BLOCK_2D		0
#define		N_FRAME				1	// time scales as long as data length scales


__device__
int  logexp_device(const int x,
	const short int Dint1, const short int Dint2, const short int Dint3	//! Decoder (lookup-table) parameters
	, int* s_logexp_table )		
{
	int ind = x >> Dint3;
	if (ind >= Dint2) // outside table
		return 0;

	// Without interpolation
	return s_logexp_table[ind];
}

__device__
int Boxplus(const int a, const int b,
	const short int Dint1, const short int Dint2, const short int Dint3,	//! Decoder (lookup-table) parameters
	const int QLLR_MAX, int* s_logexp_table )		//! The lookup tables for the decoder
{
	//return a+b;
	int a_abs = (a > 0 ? a : -a);
	int b_abs = (b > 0 ? b : -b);
	int minabs = (a_abs > b_abs ? b_abs : a_abs);
	int term1 = (a > 0 ? (b > 0 ? minabs : -minabs)
		: (b > 0 ? -minabs : minabs));

	if (Dint2 == 0) {  // logmax approximation - avoid looking into empty table
		// Don't abort when overflowing, just saturate the QLLR
		if (term1 > QLLR_MAX) {
			return QLLR_MAX;
		}
		if (term1 < -QLLR_MAX) {
			return -QLLR_MAX;
		}
		return term1;
	}

	int apb = a + b;
	int term2 = logexp_device((apb > 0 ? apb : -apb), Dint1, Dint2, Dint3, s_logexp_table );
	int amb = a - b;
	int term3 = logexp_device((amb > 0 ? amb : -amb), Dint1, Dint2, Dint3, s_logexp_table );
	int result = term1 + term2 - term3;

	// Don't abort when overflowing, just saturate the QLLR
	if (result > QLLR_MAX) {
		return QLLR_MAX;
	}
	if (result < -QLLR_MAX) {
		return -QLLR_MAX;
	}
	return result;
}

__global__ 
void updateCheckNodeOpti_kernel( const int ncheck, const int nvar, 
	const int* sumX2, const int* mvc, const int* jind, int* logexp_table, 
	const short int Dint1, const short int Dint2, const short int Dint3, 
	const int QLLR_MAX,
	int* mcv )
{	//	mvc const(input)-> mcv (output)
	int j = blockIdx.x * blockDim.x + threadIdx.x;

	if( j>= ncheck )
		return;

	__shared__ int s_logexp_table[TABLE_SIZE_DINT2];

	int SIZE_BLOCK_TRY = 137;	//	uppermost 137, > 138 fail on Tesla 2050 
	if( threadIdx.x < SIZE_BLOCK_TRY )	{
	for( int ii=0; threadIdx.x + ii * SIZE_BLOCK_TRY < TABLE_SIZE_DINT2; ii++ )
		s_logexp_table[threadIdx.x + ii * SIZE_BLOCK_TRY] = logexp_table[threadIdx.x + ii * SIZE_BLOCK_TRY];
	}
	__syncthreads();

	int ml[MAX_CHECK_NODE];//int* ml	= d_ml	+ j * max_cnd;
	int mr[MAX_CHECK_NODE];//int* mr	= d_mr	+ j * max_cnd;
	int m[MAX_CHECK_NODE];

	//if( j== ncheck )
	{
		for(int i = 0; i < sumX2[j]; i++ ) 
			m[i] = mvc[ jind[j+i*ncheck] ];
	}

	int nodes = sumX2[j];

	nodes--;

	// compute partial sums from the left and from the right
	//if( j== ncheck )
	{
		ml[0] = m[0];
		mr[0] = m[nodes];
		for(int i = 1; i < nodes; i++ ) {
			ml[i] = Boxplus( ml[i-1], m[i], Dint1, Dint2, Dint3, QLLR_MAX, s_logexp_table );
			mr[i] = Boxplus( mr[i-1], m[nodes-i], Dint1, Dint2, Dint3, QLLR_MAX, s_logexp_table );
		}
	}
	// merge partial sums
	//if( j== ncheck )
	{	
		mcv[j] = mr[nodes-1];
		mcv[j+nodes*ncheck] = ml[nodes-1];
		for(int i = 1; i < nodes; i++ )
			mcv[j+i*ncheck] = Boxplus( ml[i-1], mr[nodes-1-i], Dint1, Dint2, Dint3, QLLR_MAX, s_logexp_table );
	}
}


__global__ 
void updateVariableNodeOpti2D_kernel( const int nvar, const int ncheck, const int* sumX1, const int* mcv, const int* iind, const int * LLRin, 
	char * LLRout, int* mvc ) // not used, just for testing performance bound
{	//	mcv const(input)-> mvc (output)
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	
	if( i>= nvar )
		return;
		
	__shared__ int mvc_temp[SIZE_BLOCK_2D_X];
	__shared__ int m[MAX_VAR_NODE][SIZE_BLOCK_2D_X];
	

	if( threadIdx.y < sumX1[i] )
		m[threadIdx.y][threadIdx.x] = mcv[ iind[i + threadIdx.y*nvar] ];
	__syncthreads();

	if( threadIdx.y == 0 )
	{
		mvc_temp[threadIdx.x] = LLRin[i];

		for (int jp = 0; jp < sumX1[i]; jp++)
			mvc_temp[threadIdx.x] += m[jp][threadIdx.x];

		LLRout[i] = mvc_temp[threadIdx.x]<0;
	}
	__syncthreads();

	if( threadIdx.y < sumX1[i] )
		mvc[i + threadIdx.y*nvar] = mvc_temp[threadIdx.x] - m[threadIdx.y][threadIdx.x];
	__syncthreads();

}


bool driverUpdataChk::launch()
{
#if USE_BLOCK_2D
	
	dim3 block( SIZE_BLOCK_2D_X, MAX_VAR_NODE );
	dim3 grid;
	grid.x = (nvar * MAX_VAR_NODE + SIZE_BLOCK_2D_X * MAX_VAR_NODE - 1) 
				/ (SIZE_BLOCK_2D_X * MAX_VAR_NODE) ;

	updateVariableNodeOpti2D_kernel<<< grid, block >>>( nvar, ncheck, 
		d_sumX1, d_mcv, d_iind, d_input, 
		d_output, d_mvc );
#else

	dim3 block( SIZE_BLOCK );
	dim3 grid( (nvar + block.x - 1) / block.x );

	updateCheckNodeOpti_kernel<<< grid, block >>>( ncheck, nvar, 
		d_sumX2, d_mvc, d_jind, d_logexp_table,
		Dint1, Dint2, Dint3, QLLR_MAX,
		d_mcv );

#endif

	cudaError_t	status = cudaGetLastError();
	return status == cudaSuccess ;
}

bool driverUpdataChk::verify()
{
	cudaMemcpy( mcv, d_mcv, ncheck * nmaxX2 * sizeof(int) * N_FRAME, cudaMemcpyDeviceToHost );

	// mcv
	int i = 0;
	for ( ; i < ncheck * nmaxX2; i++ )
	{
		if ( ref_mcv[i] != mcv[i] )
			break;
	}

	if ( i < ncheck * nmaxX2 )
		return false;

	return true;
}

template <typename T>
void 	readArray(T* pArray, int nSize, char* strFileName)
{
	FILE* fp = NULL;
	fp = fopen( strFileName, "rb" );
	if(fp == NULL)
	{
		printf("failed to open: %s!\n", strFileName);
	}
	fread( pArray, sizeof(T), nSize, fp);
	fclose(fp);
}

driverUpdataChk::driverUpdataChk()
	: nvar( VAR_SIZE_CODE )
	, ncheck( CHECK_SIZE_CODE )
	, nmaxX1( MAX_VAR_NODE )
	, nmaxX2( MAX_CHECK_NODE )
{
	Dint1 = 12;	Dint2 = 300;	Dint3 = 7;	//! Decoder (lookup-table) parameters
	QLLR_MAX = (std::numeric_limits<int>::max() >> 4);

	sumX2 = (int*)malloc(ncheck * sizeof(int));
	jind = (int*)malloc(ncheck * nmaxX2 * sizeof(int));
	mvc = (int*)malloc(nvar * nmaxX1 * sizeof(int) * N_FRAME);
	mcv = (int*)malloc(ncheck * nmaxX2 * sizeof(int) * N_FRAME);
	logexp_table = (int*)malloc(Dint2 * sizeof(int) );
	ref_mcv = (int*)malloc(ncheck * nmaxX2 * sizeof(int) * N_FRAME);

	readArray( sumX2, ncheck, "../data/sumX2.txt" );

	readArray( jind, ncheck * nmaxX2, "../data/jind.txt" );

	readArray( ref_mcv, ncheck * nmaxX2, "../data/mcv.txt" );	

	readArray( mvc, nvar * nmaxX1, "../data/mvcInit.txt" );		

	readArray( logexp_table, Dint2, "../data/logexp.txt" );

	for( int i = 0; i < N_FRAME; i ++ )
	{
		memcpy( ref_mcv + i * ncheck * nmaxX2, ref_mcv,  ncheck * nmaxX2 * sizeof(int) );
		memcpy( mvc + i * nvar * nmaxX1, mvc,  nvar * nmaxX1 * sizeof(int) );
	}

	cudaMalloc( (void**)&d_sumX2, ncheck * sizeof(int) );	// const 32 K
	cudaMemcpy( d_sumX2, sumX2, ncheck * sizeof(int), cudaMemcpyHostToDevice );

	cudaMalloc( (void**)&d_jind, ncheck * nmaxX2 * sizeof(int) );	// const 300 K
	cudaMemcpy( d_jind, jind, ncheck * nmaxX2 * sizeof(int), cudaMemcpyHostToDevice );

	cudaMalloc( (void**)&d_mcv, ncheck * nmaxX2 * sizeof(int) * N_FRAME );
	cudaMemset( d_mcv, 0, ncheck * nmaxX2 * sizeof(int) * N_FRAME );

	cudaMalloc( (void**)&d_mvc, nvar * nmaxX1 * sizeof(int) * N_FRAME );
	cudaMemcpy( d_mvc, mvc, nvar * nmaxX1 * sizeof(int) * N_FRAME, cudaMemcpyHostToDevice );

	cudaMalloc( (void**)&d_logexp_table, Dint2 * sizeof(int) );		// const 1.2 K
	cudaMemcpy( d_logexp_table, logexp_table, Dint2 * sizeof(int), cudaMemcpyHostToDevice );

}

driverUpdataChk::~driverUpdataChk()
{
	// host
	free(sumX2);
	free(jind);
	free(mvc);		free(mcv);

	free(ref_mcv);
	free(logexp_table);

	// device
	cudaFree( d_sumX2 );
	cudaFree( d_jind );
	cudaFree( d_mvc );		cudaFree( d_mcv );
	cudaFree( d_logexp_table );
}