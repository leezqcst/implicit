import numpy
import cython
from cython cimport floating
from cython.parallel import parallel, prange
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy

# requires scipy v0.16
cimport scipy.linalg.cython_lapack as cython_lapack
cimport scipy.linalg.cython_blas as cython_blas

# lapack/blas wrappers for cython fused types
cdef inline void axpy(int * n, floating * da, floating * dx, int * incx, floating * dy, int * incy) nogil:
    if floating is double:
        cython_blas.daxpy(n, da, dx, incx, dy, incy)
    else:
        cython_blas.saxpy(n, da, dx, incx, dy, incy)

cdef inline void symv(char *uplo, int *n, floating *alpha, floating *a, int *lda, floating *x, int *incx, floating *beta, floating *y, int *incy) nogil:
    if floating is double:
        cython_blas.dsymv(uplo, n, alpha, a, lda, x, incx, beta, y, incy)
    else:
        cython_blas.ssymv(uplo, n, alpha, a, lda, x, incx, beta, y, incy)

cdef inline floating dot(int *n, floating *sx, int *incx, floating *sy, int *incy) nogil:
    if floating is double:
        return cython_blas.ddot(n, sx, incx, sy, incy)
    else:
        return cython_blas.sdot(n, sx, incx, sy, incy)

cdef inline void scal(int *n, floating *sa, floating *sx, int *incx) nogil:
    if floating is double:
        cython_blas.dscal(n, sa, sx, incx)
    else:
        cython_blas.sscal(n, sa, sx, incx)

cdef inline void posv(char * u, int * n, int * nrhs, floating * a, int * lda, floating * b, int * ldb, int * info) nogil:
    if floating is double:
        cython_lapack.dposv(u, n, nrhs, a, lda, b, ldb, info)
    else:
        cython_lapack.sposv(u, n, nrhs, a, lda, b, ldb, info)

cdef inline void gesv(int * n, int * nrhs, floating * a, int * lda, int * piv, floating * b, int * ldb, int * info) nogil:
    if floating is double:
        cython_lapack.dgesv(n, nrhs, a, lda, piv, b, ldb, info)
    else:
        cython_lapack.sgesv(n, nrhs, a, lda, piv, b, ldb, info)


@cython.boundscheck(False)
def least_squares(Cui, floating [:, :] X, floating [:, :] Y, double regularization, int num_threads=0):
    dtype = numpy.float64 if floating is double else numpy.float32

    cdef int [:] indptr = Cui.indptr, indices = Cui.indices
    cdef double [:] data = Cui.data

    cdef int users = X.shape[0], factors = X.shape[1], u, i, j, index, err, one = 1
    cdef floating confidence, temp

    YtY = numpy.dot(numpy.transpose(Y), Y)

    cdef floating[:, :] initialA = YtY + regularization * numpy.eye(factors, dtype=dtype)
    cdef floating[:] initialB = numpy.zeros(factors, dtype=dtype)

    cdef floating * A
    cdef floating * b
    cdef int * pivot

    with nogil, parallel(num_threads = num_threads):
        # allocate temp memory for each thread
        A = <floating *> malloc(sizeof(floating) * factors * factors)
        b = <floating *> malloc(sizeof(floating) * factors)
        pivot = <int *> malloc(sizeof(int) * factors)
        try:
            for u in prange(users, schedule='guided'):
                # For each user u calculate
                # Xu = (YtCuY + regularization*I)i^-1 * YtYCuPu

                # Build up A = YtCuY + reg * I and b = YtCuPu
                memcpy(A, &initialA[0, 0], sizeof(floating) * factors * factors)
                memcpy(b, &initialB[0], sizeof(floating) * factors)

                for index in range(indptr[u], indptr[u+1]):
                    i = indices[index]
                    confidence = data[index]

                    # b += Yi Cui Pui
                    # Pui is implicit, its defined to be 1 for non-zero entries
                    axpy(&factors, &confidence, &Y[i, 0], &one, b, &one)

                    # A += Yi^T Cui Yi
                    # Since we've already added in YtY, we subtract 1 from confidence
                    for j in range(factors):
                        temp = (confidence - 1) * Y[i, j]
                        axpy(&factors, &temp, &Y[i, 0], &one, A + j * factors, &one)

                posv("U", &factors, &one, A, &factors, b, &factors, &err);

                # fall back to using a LU decomposition if this fails
                if err:
                    gesv(&factors, &one, A, &factors, pivot, b, &factors, &err)

                if not err:
                    memcpy(&X[u, 0], b, sizeof(floating) * factors)

                else:
                    with gil:
                        raise ValueError("Singular matrix (err=%i) on row %i" % (err, u))

        finally:
            free(A)
            free(b)
            free(pivot)


@cython.cdivision(True)
@cython.boundscheck(False)
def least_squares_cg(Cui, floating [:, :] X, floating [:, :] Y, float regularization, int num_threads=0, int cg_steps=3):
    dtype = numpy.float64 if floating is double else numpy.float32
    cdef int [:] indptr = Cui.indptr, indices = Cui.indices
    cdef double [:] data = Cui.data

    cdef int users = X.shape[0], N = X.shape[1], u, i, index, one = 1, it
    cdef floating confidence, temp, alpha, rsnew, rsold
    cdef floating zero = 0.

    cdef floating[:, :] YtY = numpy.dot(numpy.transpose(Y), Y) + regularization * numpy.eye(N, dtype=dtype)

    cdef floating * x
    cdef floating * p
    cdef floating * r
    cdef floating * Ap

    with nogil, parallel(num_threads = num_threads):

        # allocate temp memory for each thread
        Ap = <floating *> malloc(sizeof(floating) * N)
        p = <floating *> malloc(sizeof(floating) * N)
        r = <floating *> malloc(sizeof(floating) * N)
        try:
            for u in prange(users, schedule='guided'):
                # start from previous iteration
                x = &X[u, 0]

                # calculate residual r = (YtCuPu - (YtCuY.dot(Xu)
                temp = -1.0
                symv("U", &N, &temp, &YtY[0, 0], &N, x, &one, &zero, r, &one)

                for index in range(indptr[u], indptr[u + 1]):
                    i = indices[index]
                    confidence = data[index]
                    temp = confidence - (confidence - 1) * dot(&N, &Y[i, 0], &one, x, &one)
                    axpy(&N, &temp, &Y[i, 0], &one, r, &one)

                memcpy(p, r, sizeof(floating) * N)
                rsold = dot(&N, r, &one, r, &one)

                for it in range(cg_steps):
                    # calculate Ap = YtCuYp - without actually calculating YtCuY
                    temp = 1.0
                    symv("U", &N, &temp, &YtY[0, 0], &N, p, &one, &zero, Ap, &one)

                    for index in range(indptr[u], indptr[u + 1]):
                        i = indices[index]
                        confidence = data[index]
                        temp = (confidence - 1) * dot(&N, &Y[i, 0], &one, p, &one)
                        axpy(&N, &temp, &Y[i, 0], &one, Ap, &one)

                    # alpha = rsold / p.dot(Ap);
                    alpha = rsold / dot(&N, p, &one, Ap, &one)

                    # x += alpha * p
                    axpy(&N, &alpha, p, &one, x, &one)

                    # r -= alpha * Ap
                    temp = alpha * -1
                    axpy(&N, &temp, Ap, &one, r, &one)

                    rsnew = dot(&N, r, &one, r, &one)

                    # p = r + (rsnew/rsold) * p
                    temp = rsnew / rsold
                    scal(&N, &temp, p, &one)
                    temp = 1.0
                    axpy(&N, &temp, r, &one, p, &one)

                    rsold = rsnew
        finally:
            free(p)
            free(r)
            free(Ap)


@cython.cdivision(True)
@cython.boundscheck(False)
def calculate_loss(Cui, floating [:, :] X, floating [:, :] Y, float regularization, int num_threads=0):
    dtype = numpy.float64 if floating is double else numpy.float32
    cdef int [:] indptr = Cui.indptr, indices = Cui.indices
    cdef double [:] data = Cui.data

    cdef int users = X.shape[0], N = X.shape[1], items = Y.shape[0], u, i, index, one = 1
    cdef floating confidence, temp
    cdef floating zero = 0.

    cdef floating[:, :] YtY = numpy.dot(numpy.transpose(Y), Y)

    cdef floating * r

    cdef double loss = 0, total_confidence = 0, item_norm = 0, user_norm = 0

    with nogil, parallel(num_threads = num_threads):
        r = <floating *> malloc(sizeof(floating) * N)
        try:
            for u in prange(users, schedule='guided'):
                # calculates (A.dot(Xu) - 2 * b).dot(Xu), without calculating A
                temp = 1.0
                symv("U", &N, &temp, &YtY[0, 0], &N, &X[u, 0], &one, &zero, r, &one)

                for index in range(indptr[u], indptr[u + 1]):
                    i = indices[index]
                    confidence = data[index]

                    temp = (confidence - 1) * dot(&N, &Y[i, 0], &one, &X[u ,0], &one) - 2 * confidence
                    axpy(&N, &temp, &Y[i, 0], &one, r, &one)

                    total_confidence += confidence
                    loss += confidence

                loss += dot(&N, r, &one, &X[u, 0], &one)
                user_norm += dot(&N, &X[u, 0], &one, &X[u, 0], &one)

            for i in prange(items, schedule='guided'):
                item_norm += dot(&N, &Y[i, 0], &one, &Y[i, 0], &one)

        finally:
            free(r)

    loss += regularization * (item_norm + user_norm)
    return loss / (total_confidence  + Cui.shape[0] * Cui.shape[1] - Cui.nnz)
