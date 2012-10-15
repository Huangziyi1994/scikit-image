""" to compile this use:
>>> python setup.py build_ext --inplace

to generate html report use:
>>> cython -a core16.pxd
"""

#cython: cdivision=True
#cython: boundscheck=False
#cython: nonecheck=False
#cython: wraparound=False

import numpy as np
cimport numpy as np
from libc.stdlib cimport malloc, free

#---------------------------------------------------------------------------
# 16 bit core kernel receives extra information about data bitdepth
#---------------------------------------------------------------------------

cdef inline _core16(np.uint16_t kernel(Py_ssize_t*, float, np.uint16_t, Py_ssize_t ,Py_ssize_t,Py_ssize_t ),
np.ndarray[np.uint16_t, ndim=2] image,
np.ndarray[np.uint8_t, ndim=2] selem,
np.ndarray[np.uint8_t, ndim=2] mask,
np.ndarray[np.uint16_t, ndim=2] out,
char shift_x, char shift_y,Py_ssize_t bitdepth):
    """ Main loop, this function computes the histogram for each image point
    - data is uint8
    - result is uint8 casted
    """

    cdef Py_ssize_t rows = image.shape[0]
    cdef Py_ssize_t cols = image.shape[1]
    cdef Py_ssize_t srows = selem.shape[0]
    cdef Py_ssize_t scols = selem.shape[1]

    cdef Py_ssize_t centre_r = int(selem.shape[0] / 2) + shift_y
    cdef Py_ssize_t centre_c = int(selem.shape[1] / 2) + shift_x

    # check that structuring element center is inside the element bounding box
    assert centre_r >= 0
    assert centre_c >= 0
    assert centre_r < srows
    assert centre_c < scols
    assert bitdepth in range(2,13)

    maxbin_list = [0,0,4,8,16,32,64,128,256,512,1024,2048,4096]
    midbin_list = [0,0,2,4,8,16,32,64,128,256,512,1024,2048]


    #set maxbin and midbin
    cdef Py_ssize_t maxbin=maxbin_list[bitdepth],midbin=midbin_list[bitdepth]

    assert (image<maxbin).all()

    image = np.ascontiguousarray(image)

    if mask is None:
        mask = np.ones((rows, cols), dtype=np.uint8)
    else:
        mask = np.ascontiguousarray(mask)

    if out is None:
        out = np.zeros((rows, cols), dtype=np.uint16)
    else:
        out = np.ascontiguousarray(out)

    # create extended image and mask
    cdef Py_ssize_t erows = rows+srows-1
    cdef Py_ssize_t ecols = cols+scols-1

    cdef np.ndarray emask = np.zeros((erows, ecols), dtype=np.uint8)
    cdef np.ndarray eimage = np.zeros((erows, ecols), dtype=np.uint16)

    eimage[centre_r:rows+centre_r,centre_c:cols+centre_c] = image
    emask[centre_r:rows+centre_r,centre_c:cols+centre_c] = mask

    mask = np.ascontiguousarray(mask)

    # define pointers to the data
    cdef np.uint16_t* eimage_data = <np.uint16_t*>eimage.data
    cdef np.uint8_t* emask_data = <np.uint8_t*>emask.data

    cdef np.uint16_t* out_data = <np.uint16_t*>out.data
    cdef np.uint16_t* image_data = <np.uint16_t*>image.data
    cdef np.uint8_t* mask_data = <np.uint8_t*>mask.data

    # define local variable types
    cdef Py_ssize_t r, c, rr, cc, s, value, local_max, i, even_row
    cdef float pop                                 # number of pixels actually inside the neighborhood (float)

    # allocate memory with malloc
    cdef Py_ssize_t max_se = srows*scols

    # number of element in each attack border
    cdef Py_ssize_t num_se_n, num_se_s, num_se_e, num_se_w

    # the current local histogram distribution
    cdef Py_ssize_t* histo = <Py_ssize_t*>malloc(maxbin * sizeof(Py_ssize_t))

    # these lists contain the relative pixel row and column for each of the 4 attack borders
    # east, west, north and south
    # e.g. se_e_r lists the rows of the east structuring element border

    cdef Py_ssize_t* se_e_r = <Py_ssize_t*>malloc(max_se * sizeof(Py_ssize_t))
    cdef Py_ssize_t* se_e_c = <Py_ssize_t*>malloc(max_se * sizeof(Py_ssize_t))
    cdef Py_ssize_t* se_w_r = <Py_ssize_t*>malloc(max_se * sizeof(Py_ssize_t))
    cdef Py_ssize_t* se_w_c = <Py_ssize_t*>malloc(max_se * sizeof(Py_ssize_t))
    cdef Py_ssize_t* se_n_r = <Py_ssize_t*>malloc(max_se * sizeof(Py_ssize_t))
    cdef Py_ssize_t* se_n_c = <Py_ssize_t*>malloc(max_se * sizeof(Py_ssize_t))
    cdef Py_ssize_t* se_s_r = <Py_ssize_t*>malloc(max_se * sizeof(Py_ssize_t))
    cdef Py_ssize_t* se_s_c = <Py_ssize_t*>malloc(max_se * sizeof(Py_ssize_t))

    # build attack and release borders
    # by using difference along axis

    t = np.hstack((selem,np.zeros((selem.shape[0],1))))
    t_e = np.diff(t,axis=1)==-1

    t = np.hstack((np.zeros((selem.shape[0],1)),selem))
    t_w = np.diff(t,axis=1)==1

    t = np.vstack((selem,np.zeros((1,selem.shape[1]))))
    t_s = np.diff(t,axis=0)==-1

    t = np.vstack((np.zeros((1,selem.shape[1])),selem))
    t_n = np.diff(t,axis=0)==1

    num_se_n = num_se_s = num_se_e = num_se_w = 0

    for r in range(srows):
        for c in range(scols):
            if t_e[r,c]:
                se_e_r[num_se_e] = r - centre_r
                se_e_c[num_se_e] = c - centre_c
                num_se_e += 1
            if t_w[r,c]:
                se_w_r[num_se_w] = r - centre_r
                se_w_c[num_se_w] = c - centre_c
                num_se_w += 1
            if t_n[r,c]:
                se_n_r[num_se_n] = r - centre_r
                se_n_c[num_se_n] = c - centre_c
                num_se_n += 1
            if t_s[r,c]:
                se_s_r[num_se_s] = r - centre_r
                se_s_c[num_se_s] = c - centre_c
                num_se_s += 1

    # initial population and histogram
    for i in range(maxbin):
        histo[i] = 0

    pop = 0

    for r in range(srows):
        for c in range(scols):
            rr = r
            cc = c
            if selem[r, c]:
                if emask_data[rr * ecols + cc]:
                    value = eimage_data[rr * ecols + cc]
                    histo[value] += 1
                    pop += 1.

    r = 0
    c = 0
    # kernel -------------------------------------------
    out_data[r * cols + c] = kernel(histo,pop,eimage_data[(r+centre_r) * ecols + c + centre_c],
        bitdepth,maxbin,midbin)
    # kernel -------------------------------------------

    # main loop
    r = 0
    for even_row in range(0,rows,2):
        # ---> west to east
        for c in range(1,cols):
            for s in range(num_se_e):
                rr = r + se_e_r[s] + centre_r
                cc = c + se_e_c[s] + centre_c
                if emask_data[rr * ecols + cc]:
                    value = eimage_data[rr * ecols + cc]
                    histo[value] += 1
                    pop += 1.
            for s in range(num_se_w):
                rr = r + se_w_r[s] + centre_r
                cc = c + se_w_c[s] + centre_c - 1
                if emask_data[rr * ecols + cc]:
                    value = eimage_data[rr * ecols + cc]
                    histo[value] -= 1
                    pop -= 1.

            # kernel -------------------------------------------
            out_data[r * cols + c] = kernel(histo,pop,eimage_data[(r+centre_r) * ecols + c + centre_c],
                bitdepth,maxbin,midbin)
            # kernel -------------------------------------------

        r += 1          # pass to the next row
        if r>=rows:
            break

            # ---> north to south
        for s in range(num_se_s):
            rr = r + se_s_r[s] + centre_r
            cc = c + se_s_c[s] + centre_c
            if emask_data[rr * ecols + cc]:
                value = eimage_data[rr * ecols + cc]
                histo[value] += 1
                pop += 1.
        for s in range(num_se_n):
            rr = r + se_n_r[s] + centre_r - 1
            cc = c + se_n_c[s] + centre_c
            if emask_data[rr * ecols + cc]:
                value = eimage_data[rr * ecols + cc]
                histo[value] -= 1
                pop -= 1.

        # kernel -------------------------------------------
        out_data[r * cols + c] = kernel(histo,pop,eimage_data[(r+centre_r) * ecols + c + centre_c],
            bitdepth,maxbin,midbin)
        # kernel -------------------------------------------

        # ---> east to west
        for c in range(cols-2,-1,-1):
            for s in range(num_se_w):
                rr = r + se_w_r[s] + centre_r
                cc = c + se_w_c[s] + centre_c
                if emask_data[rr * ecols + cc]:
                    value = eimage_data[rr * ecols + cc]
                    histo[value] += 1
                    pop += 1.
            for s in range(num_se_e):
                rr = r + se_e_r[s] + centre_r
                cc = c + se_e_c[s] + centre_c + 1
                if emask_data[rr * ecols + cc]:
                    value = eimage_data[rr * ecols + cc]
                    histo[value] -= 1
                    pop -= 1.

            # kernel -------------------------------------------
            out_data[r * cols + c] = kernel(histo,pop,eimage_data[(r+centre_r) * ecols + c + centre_c],
                bitdepth,maxbin,midbin)
            # kernel -------------------------------------------

        r += 1           # pass to the next row
        if r>=rows:
            break

        # ---> north to south
        for s in range(num_se_s):
            rr = r + se_s_r[s] + centre_r
            cc = c + se_s_c[s] + centre_c
            if emask_data[rr * ecols + cc]:
                value = eimage_data[rr * ecols + cc]
                histo[value] += 1
                pop += 1.
        for s in range(num_se_n):
            rr = r + se_n_r[s] + centre_r - 1
            cc = c + se_n_c[s] + centre_c
            if emask_data[rr * ecols + cc]:
                value = eimage_data[rr * ecols + cc]
                histo[value] -= 1
                pop -= 1.

        # kernel -------------------------------------------
        out_data[r * cols + c] = kernel(histo,pop,eimage_data[(r+centre_r) * ecols + c + centre_c],
            bitdepth,maxbin,midbin)
        # kernel -------------------------------------------

    # release memory allocated by malloc

    free(se_e_r)
    free(se_e_c)
    free(se_w_r)
    free(se_w_c)
    free(se_n_r)
    free(se_n_c)
    free(se_s_r)
    free(se_s_c)

    free(histo)

    return out
