using Base.BinaryPlatforms

# Our platform augmentation simply inspects the environment
function augment_platform!(p::Platform)
    flooblecrank_status = get(ENV, "FLOOBLECRANK", "disengaged")
    if flooblecrank_status == "engaged"
        p["flooblecrank"] = "engaged"
    else
        p["flooblecrank"] = "disengaged"
    end
    return p
end
